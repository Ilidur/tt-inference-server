#!/bin/bash
# Runs the long serving suites one after another; keeps going if one fails. Writes ~/qwen36-t3k/test_runs/long.done at the end.
T=$(cat ~/qwen36-t3k/.jwt); D=~/.local/lib/tt-inference-server/scripts/qwen36_t3k; R=~/qwen36-t3k/test_runs
rm -f $R/long.done
for s in b c d e soak; do
  echo "##### suite $s start $(date +%T)" >> $R/long.log
  SOAK_N=10 python3 $D/test_long_context.py $T Qwen/Qwen3.8-27B $s >> $R/long.log 2>&1
  echo "##### suite $s end $(date +%T) container=$(docker ps -q -f name=tt-38b-slots | wc -l) health=$(curl -s -o /dev/null -w %{http_code} localhost:8000/health)" >> $R/long.log
done
date +%T > $R/long.done
