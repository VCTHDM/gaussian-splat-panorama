#!/usr/bin/env bash
# Copy shortest-pilot keyframes/masks/scripts onto Linux ext4. Do not touch 全景素材 originals.
set -eu
export LANG=C.UTF-8
WIN="/mnt/c/Users/Administrator/Desktop/01_项目与代码/高斯破溅"
SRC="$WIN/jobs/shortest-pilot/sfm-prep"
ROOT=/opt/gs
WORK="$ROOT/work/shortest-pilot"
mkdir -p "$WORK/panos" "$WORK/masks_src" "$ROOT/scripts" "$WORK/logs"

cp -f "$WIN/scripts/sfm/python/"*.py "$ROOT/scripts/"
python3 - <<'PY'
from pathlib import Path
import json, shutil, hashlib
win = Path("/mnt/c/Users/Administrator/Desktop/01_项目与代码/高斯破溅")
src = win / "jobs/shortest-pilot/sfm-prep"
work = Path("/opt/gs/work/shortest-pilot")
kf_json = json.loads((src / "keyframes.json").read_text(encoding="utf-8"))
frames = kf_json["frames"]
mapping = []
for i, fr in enumerate(frames, start=1):
    src_name = fr["image_name"]
    src_path = src / "keyframes" / src_name
    dst_name = f"p{i:06d}.jpg"
    dst = work / "panos" / dst_name
    shutil.copy2(src_path, dst)
    h = hashlib.sha256(dst.read_bytes()).hexdigest()
    mapping.append({
        "pano_index": i,
        "pano_id": f"p{i:06d}",
        "dst_name": dst_name,
        "src_name": src_name,
        "src_frame_index": fr.get("source_frame_index"),
        "pts_time": fr.get("pts_time"),
        "window_start_sec": fr.get("window_start_sec"),
        "window_end_sec": fr.get("window_end_sec"),
        "width": fr.get("width"),
        "height": fr.get("height"),
        "laplacian_var": fr.get("laplacian_var"),
        "reason": fr.get("reason"),
        "sha256": h,
    })
shutil.copy2(src / "masks" / "nadir_body.png", work / "masks_src" / "nadir_body.png")
sky = src / "masks" / "sky_soft.png"
if sky.exists():
    shutil.copy2(sky, work / "masks_src" / "sky_soft.png")
(work / "pano_mapping.json").write_text(json.dumps({
    "count": len(mapping),
    "source_video": "全景素材/f640ef4cc3c8cbda0df51f7eb2d79368.mp4",
    "window_sec": kf_json.get("window_sec"),
    "panos": mapping,
    "nadir_body": str(work / "masks_src" / "nadir_body.png"),
}, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
print("SYNC_OK panos", len(mapping))
PY
cp -f "$WORK/pano_mapping.json" "$WIN/logs/sfm/pano_mapping.json"
echo SYNC_DONE
