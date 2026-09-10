#!/usr/bin/env bash
set -euo pipefail
export LANG=C.UTF-8 OMP_NUM_THREADS=8 OPENBLAS_NUM_THREADS=8
export PATH="/opt/gs/env/pgsr/bin:$PATH"
WIN='/mnt/c/Users/Administrator/Desktop/01_项目与代码/高斯破溅'
exec > >(tee /opt/gs/work/shortest-pilot/logs/ground-fill.log) 2>&1
python -u "$WIN/scripts/sfm/python/fill_ground_holes.py"
