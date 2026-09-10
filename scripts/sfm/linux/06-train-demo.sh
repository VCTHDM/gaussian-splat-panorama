#!/usr/bin/env bash
# Isolated demo training. Reuses shortest-pilot pgsr-data; writes only under /opt/gs/work/demo.
# Not the later pipeline entry; 06-train-pgsr.sh stays for the main job.
set -euo pipefail
export LANG=C.UTF-8 PYTHONUNBUFFERED=1
export OMP_NUM_THREADS=8 OPENBLAS_NUM_THREADS=8
export PATH="/usr/local/cuda-12.4/bin:/opt/gs/env/pgsr/bin:$PATH"
export CUDA_HOME=/usr/local/cuda-12.4
WORK=/opt/gs/work/demo
DATA=/opt/gs/work/shortest-pilot/pgsr-data
OUT="$WORK/pgsr-output"
LOGDIR="$WORK/logs"
mkdir -p "$OUT" "$LOGDIR"
test -f "$DATA/sparse/images.bin"
test -d "$DATA/images"
exec > >(tee "$LOGDIR/pgsr-train.log") 2>&1
echo "=== demo train start $(date -u +%Y-%m-%dT%H:%M:%SZ) ==="
echo "DATA=$DATA"
echo "OUT=$OUT"
cd /opt/gs/vendor/PGSR
python -u train.py -s "$DATA" -m "$OUT" -r 1 \
  --iterations 7000 --position_lr_max_steps 7000 \
  --densify_until_iter 5000 --max_abs_split_points 0 --max_all_points 400000 \
  --single_view_weight_from_iter 2000 --multi_view_weight_from_iter 2000 \
  --multi_view_sample_num 16384 --opacity_cull_threshold 0.05 \
  --save_iterations 2000 7000 --checkpoint_iterations 7000 \
  --test_iterations 7000
echo "=== demo train done $(date -u +%Y-%m-%dT%H:%M:%SZ) ==="
echo DEMO_TRAIN_DONE
