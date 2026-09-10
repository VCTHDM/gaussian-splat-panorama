#!/usr/bin/env bash
set -euo pipefail
export LANG=C.UTF-8 CUDA_HOME=/usr/local/cuda-12.4
export PATH="$CUDA_HOME/bin:/opt/gs/env/pgsr/bin:$PATH"
export TORCH_CUDA_ARCH_LIST=8.9 MAX_JOBS=4
exec > >(tee /opt/gs/work/shortest-pilot/logs/pgsr-build.log) 2>&1
cd /opt/gs/vendor/PGSR
# PGSR uses only quaternion_to_matrix from PyTorch3D. Its existing normalized
# scalar-first build_rotation implements the same operation on CUDA tensors.
python - <<'PY'
from pathlib import Path
p = Path('scene/gaussian_model.py')
s = p.read_text()
old = 'from pytorch3d.transforms import quaternion_to_matrix'
new = 'from utils.general_utils import build_rotation as quaternion_to_matrix'
if old in s:
    p.write_text(s.replace(old, new))
elif new not in s:
    raise SystemExit('pytorch3d import line not found')
PY
pip install --no-build-isolation submodules/diff-plane-rasterization submodules/simple-knn
echo PGSR_BUILD_READY
