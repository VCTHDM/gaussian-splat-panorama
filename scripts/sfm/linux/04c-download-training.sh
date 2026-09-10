#!/usr/bin/env bash
set -euo pipefail
export LANG=C.UTF-8
WIN='/mnt/c/Users/Administrator/Desktop/01_项目与代码/高斯破溅'
/opt/gs/env/gs-sfm/bin/python -u "$WIN/scripts/sfm/python/download_training_wheels.py" 2>&1 | tee /opt/gs/work/shortest-pilot/logs/cuda-download.log
