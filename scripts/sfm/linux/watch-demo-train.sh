#!/usr/bin/env bash
# Silent until DONE / FAILED / ACTION_REQUIRED. Poll 30s.
set -eu
LOG=/opt/gs/work/demo/logs/pgsr-train.log
PLY2=/opt/gs/work/demo/pgsr-output/point_cloud/iteration_2000/point_cloud.ply
PLY7=/opt/gs/work/demo/pgsr-output/point_cloud/iteration_7000/point_cloud.ply
FLAG=/opt/gs/work/demo/logs/notified-2000
DIAG=/opt/gs/work/demo/logs/watch-diag.log
mkdir -p "$(dirname "$LOG")"

alive() {
  pgrep -af 'train.py' 2>/dev/null | grep -q 'pgsr-data' || return 1
}

err_line() {
  grep -E 'CUDA out of memory|RuntimeError:|Traceback \(most recent call last\)|No CUDA GPUs are available|AssertionError' "$LOG" 2>/dev/null | tail -1 || true
}

started=0
while :; do
  if [ -f "$LOG" ]; then
    if grep -q 'DEMO_TRAIN_DONE' "$LOG"; then
      if [ -f "$PLY7" ]; then
        echo DONE
        exit 0
      fi
      echo 'FAILED: DEMO_TRAIN_DONE without iteration_7000 ply'
      exit 1
    fi
    err=$(err_line)
    if [ -n "$err" ] && ! alive; then
      echo "FAILED: $err"
      exit 1
    fi
    if grep -qE 'Loss:|\[ITER |Training progress' "$LOG"; then
      started=1
    fi
    if [ -f "$PLY2" ] && [ ! -f "$FLAG" ]; then
      touch "$FLAG"
      echo 'ACTION_REQUIRED: iteration 2000 ply ready'
    fi
  fi
  if [ "$started" = 1 ] && ! alive; then
    sleep 8
    if [ -f "$LOG" ] && grep -q 'DEMO_TRAIN_DONE' "$LOG" && [ -f "$PLY7" ]; then
      echo DONE
      exit 0
    fi
    if ! alive; then
      echo 'FAILED: train process exited early'
      tail -20 "$LOG" 2>/dev/null | tr '\n' ' '
      echo
      exit 1
    fi
  fi
  date -u +'%Y-%m-%dT%H:%M:%SZ started='"$started"' alive='$(alive && echo 1 || echo 0) >>"$DIAG"
  sleep 30
done
