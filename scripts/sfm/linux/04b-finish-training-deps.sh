#!/usr/bin/env bash
set -euo pipefail
export LANG=C.UTF-8
exec > >(tee /opt/gs/work/shortest-pilot/logs/training-deps.log) 2>&1
PIP=/opt/gs/env/pgsr/bin/pip
# Preserve the completed official cu124 wheels; resolve remaining NVIDIA wheels
# through PyPI because pypi.nvidia.com was transferring only ~0.3 MB/s.
$PIP install --no-index --find-links /opt/gs/cache/training --no-deps \
  /opt/gs/cache/training/nvidia_*.whl \
  /opt/gs/cache/training/triton-*.whl \
  /opt/gs/cache/training/torch-*.whl \
  /opt/gs/cache/training/torchvision-*.whl
$PIP install 'numpy<2' open3d plyfile opencv-python-headless lpips trimesh tqdm scipy ninja tensorboard
echo TRAINING_DEPS_READY
