#!/usr/bin/env bash
# Progress readout for a SWE-bench Pro run, replacing the rich Live UI that
# disappears when the run's stdout is piped (tee) instead of a TTY.
RUN_ID="${RUN_ID:?set RUN_ID}"
cd "$(dirname "$0")/.."
PREDS="jobs/$RUN_ID/swebench-pro/preds/preds.json"
TOTAL="${TOTAL:-200}"
while true; do
  n=$(python3 -c "import json;print(len(json.load(open('$PREDS'))))" 2>/dev/null || echo 0)
  run=$(docker ps --filter name=minisweagent- -q | wc -l)
  printf "\r%s  preds %3s/%s  containers %2s  /mnt %s free   " \
    "$(date '+%H:%M:%S')" "$n" "$TOTAL" "$run" "$(df -h --output=avail /mnt | tail -1 | tr -d ' ')"
  sleep 10
done
