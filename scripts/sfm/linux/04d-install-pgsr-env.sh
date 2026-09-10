#!/usr/bin/env bash
# Finish PGSR env on cu124 only: wheels, torch, python deps, CUDA extensions.
set -euo pipefail
export LANG=C.UTF-8
export DEBIAN_FRONTEND=noninteractive
WIN='/mnt/c/Users/Administrator/Desktop/01_项目与代码/高斯破溅'
CACHE=/opt/gs/cache/training
VENV=/opt/gs/env/pgsr
PGSR=/opt/gs/vendor/PGSR
LOGDIR=/opt/gs/work/shortest-pilot/logs
mkdir -p "$CACHE" "$LOGDIR"
exec > >(tee "$LOGDIR/pgsr-env.log") 2>&1

echo "=== pgsr env start $(date -u +%Y-%m-%dT%H:%M:%SZ) ==="
test -x "$VENV/bin/python"
test -d "$PGSR/submodules/diff-plane-rasterization"
test -d "$PGSR/submodules/simple-knn"
test -x /usr/local/cuda-12.4/bin/nvcc

# Reuse the two wheels already fetched and hash-checked in /tmp.
if [ -f /tmp/nvtx-test.whl ]; then
  cp -f /tmp/nvtx-test.whl "$CACHE/nvidia_nvtx_cu12-12.4.99-py3-none-manylinux2014_x86_64.whl"
fi
if [ -f /tmp/nvjitlink-test.whl ]; then
  cp -f /tmp/nvjitlink-test.whl "$CACHE/nvidia_nvjitlink_cu12-12.4.99-py3-none-manylinux2014_x86_64.whl"
fi

if [ -f "$CACHE/triton-3.0.0-1-cp310-cp310-manylinux2014_x86_64.manylinux_2_17_x86_64.whl" ] \
   && [ ! -f "$CACHE/triton-3.0.0-1-cp310-cp310-manylinux2014_x86_64.manylinux_2_17_x86_64.whl.aria2" ]; then
  echo "=== wheels already complete, skip download ==="
else
  /opt/gs/env/gs-sfm/bin/python -u "$WIN/scripts/sfm/python/download_training_wheels.py"
fi

PIP="$VENV/bin/pip"
echo "=== pip nvidia/triton from local cache ==="
"$PIP" install --no-index --find-links "$CACHE" --no-deps \
  "$CACHE"/nvidia_*.whl \
  "$CACHE"/triton-*.whl

echo "=== pip torch/torchvision no-deps from local cache ==="
"$PIP" install --no-index --find-links "$CACHE" --no-deps \
  "$CACHE"/torch-2.4.1+cu124-cp310-cp310-linux_x86_64.whl \
  "$CACHE"/torchvision-0.19.1+cu124-cp310-cp310-linux_x86_64.whl

echo "=== pip torch python deps and PGSR packages from TUNA ==="
"$PIP" install -i https://pypi.tuna.tsinghua.edu.cn/simple \
  filelock 'typing-extensions>=4.8.0' sympy networkx jinja2 fsspec \
  'numpy<2' 'pillow!=8.3.*,>=5.3.0' markupsafe 'mpmath<1.4,>=1.1.0' \
  open3d plyfile opencv-python-headless lpips trimesh tqdm scipy ninja tensorboard

echo "=== patch pytorch3d import ==="
"$VENV/bin/python" - <<'PY'
from pathlib import Path
p = Path('/opt/gs/vendor/PGSR/scene/gaussian_model.py')
s = p.read_text()
old = 'from pytorch3d.transforms import quaternion_to_matrix'
new = 'from utils.general_utils import build_rotation as quaternion_to_matrix'
if old in s:
    p.write_text(s.replace(old, new))
    print('PATCHED', p)
elif new in s:
    print('ALREADY_PATCHED', p)
else:
    raise SystemExit('pytorch3d import line not found')
PY

echo "=== build CUDA extensions ==="
export CUDA_HOME=/usr/local/cuda-12.4
export PATH="$CUDA_HOME/bin:$VENV/bin:$PATH"
export TORCH_CUDA_ARCH_LIST=8.9
export MAX_JOBS=4
export CPATH="${CUDA_HOME}/include${CPATH:+:$CPATH}"
export LIBRARY_PATH="${CUDA_HOME}/lib64${LIBRARY_PATH:+:$LIBRARY_PATH}"
cd "$PGSR"
"$PIP" install --no-build-isolation submodules/diff-plane-rasterization submodules/simple-knn

echo "=== verify ==="
"$VENV/bin/python" - <<'PY'
import torch, cv2, open3d, plyfile
print('torch', torch.__version__, 'cuda', torch.version.cuda)
print('cuda_available', torch.cuda.is_available())
print('device', torch.cuda.get_device_name(0) if torch.cuda.is_available() else None)
x = torch.zeros(8, device='cuda') + 1
print('tensor_sum', float(x.sum()))
import diff_plane_rasterization
import simple_knn._C
print('diff_plane_rasterization', diff_plane_rasterization.__file__)
print('simple_knn', simple_knn._C)
print('PGSR_ENV_READY')
PY
echo "=== pgsr env done $(date -u +%Y-%m-%dT%H:%M:%SZ) ==="
