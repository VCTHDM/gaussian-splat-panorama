#!/usr/bin/env bash
set -euo pipefail
export LANG=C.UTF-8 DEBIAN_FRONTEND=noninteractive
exec > >(tee /opt/gs/work/shortest-pilot/logs/training-setup.log) 2>&1
curl -fsSL --max-time 120 https://developer.download.nvidia.com/compute/cuda/repos/wsl-ubuntu/x86_64/cuda-keyring_1.1-1_all.deb -o /opt/gs/cache/cuda-keyring_1.1-1_all.deb
dpkg -i /opt/gs/cache/cuda-keyring_1.1-1_all.deb
apt-get update
apt-get install -y --no-install-recommends build-essential python3-dev cuda-nvcc-12-4 cuda-cudart-dev-12-4 cuda-cccl-12-4 libgl1 libglib2.0-0
python3 -m venv /opt/gs/env/pgsr
PIP=/opt/gs/env/pgsr/bin/pip
$PIP install --upgrade pip setuptools wheel
$PIP install torch==2.4.1 torchvision==0.19.1 --index-url https://download.pytorch.org/whl/cu124
$PIP install 'numpy<2' open3d plyfile opencv-python-headless lpips trimesh tqdm scipy ninja tensorboard
echo TRAINING_DEPS_READY
