#!/usr/bin/env bash
set -euo pipefail
export LANG=C.UTF-8 OMP_NUM_THREADS=8 OPENBLAS_NUM_THREADS=8
WIN='/mnt/c/Users/Administrator/Desktop/01_项目与代码/高斯破溅'
cp "$WIN/scripts/sfm/python/run_shortest.py" /opt/gs/scripts/
/opt/gs/env/gs-sfm/bin/python -u /opt/gs/scripts/run_shortest.py 2>&1 | tee /opt/gs/work/shortest-pilot/logs/sfm384.log
