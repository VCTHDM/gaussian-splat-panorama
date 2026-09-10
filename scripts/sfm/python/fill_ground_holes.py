"""Fill enclosed holes in the PGSR ground mesh along the walking path.

The nadir of each panorama is the operator/camera body (already masked in SfM).
TSDF therefore has no depth under the trajectory and leaves a courtyard pit.
This fills only enclosed empty cells in the ground band; it does not retrain.
"""
from pathlib import Path
import json
import numpy as np
import open3d as o3d
from scipy import ndimage
from scipy.interpolate import LinearNDInterpolator, NearestNDInterpolator

work = Path('/opt/gs/work/shortest-pilot')
win = Path('/mnt/c/Users/Administrator/Desktop/01_项目与代码/高斯破溅/jobs/shortest-pilot/results')
src = work / 'pgsr-output/mesh/tsdf_fusion_post.ply'
out_linux = work / 'pgsr-output/mesh/tsdf_fusion_filled.ply'
out_win = win / 'terrain-filled.ply'
cfg = json.loads((win / 'viewer-config.json').read_text())
up = np.array(cfg['up'], dtype=np.float64)
up /= np.linalg.norm(up)
cam = np.array(cfg['position'], dtype=np.float64)
cam_h = float(cam @ up)

print('LOAD', src, flush=True)
mesh = o3d.io.read_triangle_mesh(str(src))
mesh.compute_vertex_normals()
xyz = np.asarray(mesh.vertices)
nrm = np.asarray(mesh.vertex_normals)
cols = np.asarray(mesh.vertex_colors) if mesh.has_vertex_colors() else None
tris = np.asarray(mesh.triangles)
h = xyz @ up
flat = nrm @ up
ground = (flat > 0.45) & (h > cam_h - 2.4) & (h < cam_h + 0.9)
print('verts', len(xyz), 'ground', int(ground.sum()), 'cam_h', cam_h, flush=True)

axis = np.array([1.0, 0.0, 0.0])
axis = axis - up * (axis @ up)
axis /= np.linalg.norm(axis)
baxis = np.cross(up, axis)
gxyz = xyz[ground]
guv = np.stack([gxyz @ axis, gxyz @ baxis], 1)
gh = h[ground]
# Pad slightly so morphological close can seal small gaps around the pit rim.
pad = 0.35
lo = guv.min(0) - pad
hi = guv.max(0) + pad
extent = hi - lo
cell = 0.08
nx = int(np.ceil(extent[0] / cell)) + 1
ny = int(np.ceil(extent[1] / cell)) + 1
nx = min(max(nx, 32), 420)
ny = min(max(ny, 32), 420)
print('grid', nx, ny, 'cell', cell, flush=True)

ix = np.clip(((guv[:, 0] - lo[0]) / (hi[0] - lo[0] + 1e-9) * (nx - 1)).astype(int), 0, nx - 1)
iy = np.clip(((guv[:, 1] - lo[1]) / (hi[1] - lo[1] + 1e-9) * (ny - 1)).astype(int), 0, ny - 1)
occ = np.zeros((ny, nx), np.uint8)
np.add.at(occ, (iy, ix), 1)
height = np.zeros((ny, nx), np.float64)
count = np.zeros((ny, nx), np.int32)
np.add.at(count, (iy, ix), 1)
np.add.at(height, (iy, ix), gh)
height = np.divide(height, count, out=np.full_like(height, np.nan), where=count > 0)

binary = occ > 0
closed = ndimage.binary_closing(binary, iterations=3)
filled = ndimage.binary_fill_holes(closed)
holes = filled & ~binary
# Drop hole components that touch the grid border (outside courtyard).
lab, nlab = ndimage.label(holes)
keep = np.zeros_like(holes)
for i in range(1, nlab + 1):
    ys, xs = np.where(lab == i)
    if ys.min() == 0 or xs.min() == 0 or ys.max() == ny - 1 or xs.max() == nx - 1:
        continue
    if len(ys) < 4:
        continue
    keep[lab == i] = True
print('hole cells', int(keep.sum()), 'components kept', int(len(np.unique(lab[keep])) - (0 in lab[keep])), flush=True)

known = np.isfinite(height)
yy, xx = np.where(known)
interp_lin = LinearNDInterpolator(np.stack([xx, yy], 1), height[known])
interp_nn = NearestNDInterpolator(np.stack([xx, yy], 1), height[known])
hy, hx = np.where(keep)
pred = interp_lin(np.stack([hx, hy], 1))
miss = ~np.isfinite(pred)
if miss.any():
    pred[miss] = interp_nn(np.stack([hx[miss], hy[miss]], 1))

new_xyz = []
new_col = []
mean_col = cols[ground].mean(0) if cols is not None else np.array([0.45, 0.42, 0.38])
for x, y, hv in zip(hx, hy, pred):
    u = lo[0] + x / (nx - 1) * (hi[0] - lo[0])
    v = lo[1] + y / (ny - 1) * (hi[1] - lo[1])
    p = axis * u + baxis * v + up * float(hv)
    new_xyz.append(p)
    new_col.append(mean_col)
new_xyz = np.array(new_xyz).reshape(-1, 3)
new_col = np.array(new_col).reshape(-1, 3)
print('new verts', len(new_xyz), flush=True)

# Raise crater cells: median of a ~0.5 m neighborhood, only lift deep dips.
fillval = float(np.nanmedian(height))
robust = ndimage.median_filter(np.where(np.isfinite(height), height, fillval), size=7)
gidx = np.where(ground)[0]
gix = np.clip(((guv[:, 0] - lo[0]) / (hi[0] - lo[0] + 1e-9) * (nx - 1)).astype(int), 0, nx - 1)
giy = np.clip(((guv[:, 1] - lo[1]) / (hi[1] - lo[1] + 1e-9) * (ny - 1)).astype(int), 0, ny - 1)
local = robust[giy, gix]
delta = local - gh
lift = np.isfinite(delta) & (delta > 0.35)
xyz = xyz.copy()
xyz[gidx[lift]] = xyz[gidx[lift]] + up[None, :] * delta[lift][:, None]
print('lifted crater verts', int(lift.sum()), 'mean lift', float(delta[lift].mean()) if lift.any() else 0, flush=True)

# Index map from grid cell to new vertex, then triangulate 2x2 hole neighborhoods.
slot = -np.ones((ny, nx), np.int32)
slot[hy, hx] = np.arange(len(new_xyz))
new_tris = []
base = len(xyz)
for y in range(ny - 1):
    for x in range(nx - 1):
        a00, a10 = slot[y, x], slot[y, x + 1]
        a01, a11 = slot[y + 1, x], slot[y + 1, x + 1]
        ids = [a00, a10, a11, a01]
        if sum(i >= 0 for i in ids) < 3:
            continue
        pts = [base + i for i in ids if i >= 0]
        if len(pts) == 4:
            new_tris.append([pts[0], pts[1], pts[2]])
            new_tris.append([pts[0], pts[2], pts[3]])
        elif len(pts) == 3:
            new_tris.append(pts)
new_tris = np.array(new_tris, dtype=np.int32).reshape(-1, 3)
print('new tris', len(new_tris), flush=True)

out = o3d.geometry.TriangleMesh()
all_xyz = np.vstack([xyz, new_xyz]) if len(new_xyz) else xyz
all_tris = np.vstack([tris, new_tris]) if len(new_tris) else tris
out.vertices = o3d.utility.Vector3dVector(all_xyz)
out.triangles = o3d.utility.Vector3iVector(all_tris)
if cols is not None:
    out.vertex_colors = o3d.utility.Vector3dVector(np.vstack([cols, new_col]) if len(new_xyz) else cols)
out.remove_degenerate_triangles()
out.remove_duplicated_triangles()
out.remove_unreferenced_vertices()
out.compute_vertex_normals()
out_linux.parent.mkdir(parents=True, exist_ok=True)
o3d.io.write_triangle_mesh(str(out_linux), out, write_vertex_colors=True, write_vertex_normals=True)
o3d.io.write_triangle_mesh(str(out_win), out, write_vertex_colors=True, write_vertex_normals=True)
print('WROTE', out_linux, 'verts', len(out.vertices), 'tris', len(out.triangles), flush=True)
print('GROUND_FILL_DONE', flush=True)
