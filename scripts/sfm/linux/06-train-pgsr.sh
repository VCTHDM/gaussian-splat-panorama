#!/usr/bin/env bash
# Full PGSR training for the 47.6s shortest video. Writes shortest-pilot, not demo.
set -euo pipefail
export LANG=C.UTF-8 PYTHONUNBUFFERED=1
export OMP_NUM_THREADS=8 OPENBLAS_NUM_THREADS=8
export PATH="/usr/local/cuda-12.4/bin:/opt/gs/env/pgsr/bin:$PATH"
export CUDA_HOME=/usr/local/cuda-12.4
WORK=/opt/gs/work/shortest-pilot
DATA="$WORK/pgsr-data"
OUT="$WORK/pgsr-output"
LOGDIR="$WORK/logs"
mkdir -p "$OUT" "$LOGDIR"
test -f "$DATA/sparse/images.bin"
test -d "$DATA/images"
exec > >(tee "$LOGDIR/pgsr-train.log") 2>&1
echo "=== full train start $(date -u +%Y-%m-%dT%H:%M:%SZ) ==="
cd /opt/gs/vendor/PGSR
python -u train.py -s "$DATA" -m "$OUT" -r 1 \
  --iterations 30000 --position_lr_max_steps 30000 \
  --densify_until_iter 15000 --max_abs_split_points 0 --max_all_points 1000000 \
  --single_view_weight_from_iter 2000 --multi_view_weight_from_iter 2000 \
  --multi_view_sample_num 16384 --opacity_cull_threshold 0.05 \
  --save_iterations 7000 15000 30000 --checkpoint_iterations 15000 30000 \
  --test_iterations 7000 15000 30000
echo "=== full train done $(date -u +%Y-%m-%dT%H:%M:%SZ) ==="
echo FULL_TRAIN_DONE
