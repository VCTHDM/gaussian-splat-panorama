#!/usr/bin/env bash
set -eu
LOG=/opt/gs/work/shortest-pilot/logs/pgsr-train.log
PLY7=/opt/gs/work/shortest-pilot/pgsr-output/point_cloud/iteration_7000/point_cloud.ply
PLY15=/opt/gs/work/shortest-pilot/pgsr-output/point_cloud/iteration_15000/point_cloud.ply
PLY30=/opt/gs/work/shortest-pilot/pgsr-output/point_cloud/iteration_30000/point_cloud.ply
FLAG7=/opt/gs/work/shortest-pilot/logs/notified-7000
FLAG15=/opt/gs/work/shortest-pilot/logs/notified-15000
DIAG=/opt/gs/work/shortest-pilot/logs/watch-full-diag.log
mkdir -p "$(dirname "$LOG")"

alive() {
  pgrep -af 'train.py' 2>/dev/null | grep -q 'shortest-pilot/pgsr-data' || return 1
}

err_line() {
  grep -E 'CUDA out of memory|RuntimeError:|Traceback \(most recent call last\)|No CUDA GPUs are available|AssertionError' "$LOG" 2>/dev/null | tail -1 || true
}

started=0
while :; do
  if [ -f "$LOG" ]; then
    if grep -q 'FULL_TRAIN_DONE' "$LOG"; then
      if [ -f "$PLY30" ]; then
        echo DONE
        exit 0
      fi
      echo 'FAILED: FULL_TRAIN_DONE without iteration_30000 ply'
      exit 1
    fi
    err=$(err_line)
    if [ -n "$err" ] && ! alive; then
      echo "FAILED: $err"
      exit 1
    fi
    if grep -qE 'Loss:|Training progress' "$LOG"; then
      started=1
    fi
    if [ -f "$PLY7" ] && [ ! -f "$FLAG7" ]; then
      touch "$FLAG7"
      echo 'ACTION_REQUIRED: iteration 7000 ply ready'
    fi
    if [ -f "$PLY15" ] && [ ! -f "$FLAG15" ]; then
      touch "$FLAG15"
      echo 'ACTION_REQUIRED: iteration 15000 ply ready'
    fi
  fi
  if [ "$started" = 1 ] && ! alive; then
    sleep 8
    if [ -f "$LOG" ] && grep -q 'FULL_TRAIN_DONE' "$LOG" && [ -f "$PLY30" ]; then
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
  date -u +'%Y-%m-%dT%H:%M:%SZ' >>"$DIAG"
  sleep 30
done
