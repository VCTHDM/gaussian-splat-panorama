#!/usr/bin/env bash
set -euo pipefail
export LANG=C.UTF-8 OMP_NUM_THREADS=8 OPENBLAS_NUM_THREADS=8
WIN='/mnt/c/Users/Administrator/Desktop/01_项目与代码/高斯破溅'
/opt/gs/env/gs-sfm/bin/python -u "$WIN/scripts/sfm/python/connect_shortest.py" 2>&1 | tee /opt/gs/work/shortest-pilot/logs/sfm384-wide.log
