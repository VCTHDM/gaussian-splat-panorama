"""Export the largest rig model to PGSR's flat PINHOLE dataset layout."""
from pathlib import Path
import json
import shutil
import numpy as np
import pycolmap as pc

work = Path('/opt/gs/work/shortest-pilot')
sfm = work / 'sfm384'
result = json.loads((sfm / 'result.json').read_text())
rec = pc.Reconstruction(sfm / 'sparse' / str(result['best_model']))
dataset = work / 'pgsr-data'
(dataset / 'images').mkdir(parents=True, exist_ok=True)
(dataset / 'sparse').mkdir(exist_ok=True)
for camera in rec.cameras.values():
    f, cx, cy = camera.params
    camera.model = pc.CameraModelId.PINHOLE
    camera.params = np.array([f, f, cx, cy])
mapping = []
for image in rec.images.values():
    original = image.name
    flat = original.replace('/', '_')
    shutil.copy2(sfm / 'images' / original, dataset / 'images' / flat)
    image.name = flat
    mapping.append({'image_id': image.image_id, 'source': original, 'training': flat})
rec.write(dataset / 'sparse')
rec.write_text(dataset / 'sparse')
(dataset / 'image_mapping.json').write_text(json.dumps(mapping, indent=2))
win = Path('/mnt/c/Users/Administrator/Desktop/01_项目与代码/高斯破溅/jobs/shortest-pilot/results')
win.mkdir(parents=True, exist_ok=True)
shutil.copy2(sfm / 'sparse.ply', win / 'sparse-local.ply')
shutil.copy2(sfm / 'result.json', win / 'sfm-result.json')
horizontal = sorted([im for im in rec.images.values() if im.name.startswith('pano_camera4_')], key=lambda im: im.name)
im = horizontal[len(horizontal) // 2]
pose = im.cam_from_world()
rotation = pose.rotation.matrix()
position = im.projection_center()
xyz = np.array([p.xyz for p in rec.points3D.values()])
distance = float(np.median(np.linalg.norm(xyz - position, axis=1)))
up = -rotation[1]
viewer_config = {'position': position.tolist(), 'lookAt': (position + rotation[2] * distance * .5).tolist(),
                 'up': up.tolist(), 'distance': distance, 'reference': im.name,
                 'registered_panos': rec.num_reg_frames(), 'points': rec.num_points3D()}
center = np.median(xyz, axis=0)
viewer_config['overviewLookAt'] = center.tolist()
viewer_config['overviewPosition'] = (center + up * distance * .9 - rotation[2] * distance * 1.4).tolist()
(win / 'viewer-config.json').write_text(json.dumps(viewer_config, indent=2))
shutil.copy2(dataset / 'images' / im.name, win / 'reference.jpg')
print('PGSR_DATA_READY', dataset, len(mapping), flush=True)
