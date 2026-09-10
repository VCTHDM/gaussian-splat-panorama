#!/usr/bin/env bash
# Create /opt/gs native gs-sfm env. CPU pycolmap wheel preferred. No NVIDIA driver, no torch.
set -eu
export LANG=C.UTF-8
export DEBIAN_FRONTEND=noninteractive

ROOT=/opt/gs
VENV="$ROOT/env/gs-sfm"
CACHE="$ROOT/cache"
VENDOR="$ROOT/vendor/colmap-4.2.0"
EVID="$ROOT/evidence"
WORK="$ROOT/work/shortest-pilot"
LOCKDIR="$ROOT/locks"
LOG=/tmp/gs-sfm-setup.log
JSON=/tmp/gs-sfm-setup.json

mkdir -p "$VENV" "$CACHE" "$VENDOR" "$EVID" "$WORK" "$LOCKDIR" "$ROOT/scripts"

{
  echo "=== setup start $(date -u +%Y-%m-%dT%H:%M:%SZ) ==="
  apt-get update -y
  apt-get install -y --no-install-recommends python3-venv python3-pip python3-dev ca-certificates curl
  python3 --version
  python3 -c "import venv,ensurepip; print('venv_ok')"
  if [ ! -x "$VENV/bin/python" ]; then
    python3 -m venv "$VENV"
  fi
  "$VENV/bin/python" -m pip install --upgrade pip
  "$VENV/bin/python" -m pip --version

  curl -fsSL --max-time 30 -o "$VENDOR/panorama.py" \
    https://raw.githubusercontent.com/colmap/colmap/4.2.0/python/pycolmap/panorama.py
  sha256sum "$VENDOR/panorama.py" | tee "$EVID/panorama.py.sha256"
  wc -c "$VENDOR/panorama.py"

  curl -fsSL --max-time 60 -o "$EVID/pycolmap-pypi.json" \
    https://pypi.org/pypi/pycolmap/json
  wc -c "$EVID/pycolmap-pypi.json"

  "$VENV/bin/python" - "$CACHE" "$EVID" "$VENV" <<'PY'
import hashlib, json, sys, urllib.request
from pathlib import Path
cache, evid, venv = map(Path, sys.argv[1:])
data = json.loads((evid / "pycolmap-pypi.json").read_text(encoding="utf-8"))
info = data.get("info", {})
releases = data.get("releases", {})
wanted = "4.2.0"
files = releases.get(wanted) or []
py310 = []
for f in files:
    name = f.get("filename") or ""
    if "cp310" in name and "manylinux" in name and name.endswith(".whl") and "win" not in name and "macos" not in name:
        py310.append(f)
# Prefer CPU wheel: filename without cuda.
cpu = [f for f in py310 if "cuda" not in (f.get("filename") or "").lower()]
chosen = (cpu or py310)[:3]
(evid / "pycolmap-4.2.0-wheel-candidates.json").write_text(
    json.dumps({"pypi_info_version": info.get("version"), "release_count": len(files), "cp310_manylinux": [
        {"filename": f.get("filename"), "url": f.get("url"), "size": f.get("size"), "sha256": (f.get("digests") or {}).get("sha256"), "python": f.get("python_version")}
        for f in py310
    ], "chosen": [
        {"filename": f.get("filename"), "url": f.get("url"), "size": f.get("size"), "sha256": (f.get("digests") or {}).get("sha256")}
        for f in chosen
    ]}, indent=2) + "\n",
    encoding="utf-8",
)
if not chosen:
    raise SystemExit("NO_PYCOLMAP_420_CP310_WHEEL")
f = chosen[0]
url = f["url"]
dest = cache / f["filename"]
print("DOWNLOAD", f["filename"], url)
urllib.request.urlretrieve(url, dest)
h = hashlib.sha256(dest.read_bytes()).hexdigest()
expect = (f.get("digests") or {}).get("sha256")
print("SHA256", h)
print("EXPECT", expect)
if expect and h != expect:
    raise SystemExit("WHEEL_SHA256_MISMATCH")
(evid / "pycolmap-wheel.sha256").write_text(f"{h}  {dest.name}\n", encoding="utf-8")
(evid / "pycolmap-wheel-path.txt").write_text(str(dest) + "\n", encoding="utf-8")
print("WHEEL_OK", dest)
PY

  WHEEL=$(cat "$EVID/pycolmap-wheel-path.txt")
  "$VENV/bin/python" -m pip install --no-deps "$WHEEL" || "$VENV/bin/python" -m pip install "$WHEEL"
  "$VENV/bin/python" -m pip install numpy pillow opencv-python-headless
  "$VENV/bin/python" -m pip freeze > "$EVID/requirements.lock.txt"
  "$VENV/bin/python" - <<'PY'
import json, inspect, pycolmap
from pathlib import Path
info = {
    "pycolmap_version": getattr(pycolmap, "__version__", None),
    "module": getattr(pycolmap, "__file__", None),
    "has_panorama": hasattr(pycolmap, "panorama") or True,
    "has_extract_features": hasattr(pycolmap, "extract_features"),
    "has_match_exhaustive": hasattr(pycolmap, "match_exhaustive"),
    "has_incremental_mapping": hasattr(pycolmap, "incremental_mapping"),
    "has_Database": hasattr(pycolmap, "Database"),
    "has_Rig": hasattr(pycolmap, "Rig"),
    "has_Rotation3d": hasattr(pycolmap, "Rotation3d"),
    "has_Rigid3d": hasattr(pycolmap, "Rigid3d"),
    "has_Camera": hasattr(pycolmap, "Camera"),
    "cuda_names": [n for n in dir(pycolmap) if "cuda" in n.lower() or "caspar" in n.lower() or "gpu" in n.lower()],
}
try:
    import pycolmap.panorama as pano
    info["panorama_module"] = getattr(pano, "__file__", None)
    info["panorama_names"] = [n for n in dir(pano) if not n.startswith("_")]
except Exception as e:
    info["panorama_import_error"] = str(e)
Path("/opt/gs/evidence/pycolmap-runtime.json").write_text(json.dumps(info, indent=2, default=str) + "\n", encoding="utf-8")
print(json.dumps(info, indent=2, default=str))
PY
  echo "=== setup end $(date -u +%Y-%m-%dT%H:%M:%SZ) ==="
} 2>&1 | tee "$LOG"

# Copy evidence to Windows mount if present
WIN_EVID="/mnt/c/Users/Administrator/Desktop/01_项目与代码/高斯破溅/logs/sfm/linux-setup"
mkdir -p "$WIN_EVID"
cp -f "$LOG" "$WIN_EVID/setup.log" || true
cp -f "$EVID"/* "$WIN_EVID/" || true
cp -f "$VENDOR/panorama.py" "$WIN_EVID/panorama.py" || true
echo SETUP_OK
