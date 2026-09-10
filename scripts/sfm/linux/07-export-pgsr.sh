#!/usr/bin/env bash
set -euo pipefail
export LANG=C.UTF-8 OMP_NUM_THREADS=8 OPENBLAS_NUM_THREADS=8
export PATH="/opt/gs/env/pgsr/bin:$PATH"
cd /opt/gs/vendor/PGSR
python -u render.py -m /opt/gs/work/shortest-pilot/pgsr-output \
  --iteration 30000 --max_depth 30 --voxel_size 0.04 --use_depth_filter --skip_test \
  2>&1 | tee /opt/gs/work/shortest-pilot/logs/pgsr-export.log
WIN='/mnt/c/Users/Administrator/Desktop/01_项目与代码/高斯破溅/jobs/shortest-pilot/results'
cp /opt/gs/work/shortest-pilot/pgsr-output/point_cloud/iteration_30000/point_cloud.ply "$WIN/gaussian-local.ply"
cp /opt/gs/work/shortest-pilot/pgsr-output/mesh/tsdf_fusion.ply "$WIN/terrain-raw.ply"
cp /opt/gs/work/shortest-pilot/pgsr-output/mesh/tsdf_fusion_post.ply "$WIN/terrain-reference.ply"
