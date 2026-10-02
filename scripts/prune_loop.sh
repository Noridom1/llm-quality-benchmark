#!/usr/bin/env bash
# Keep /mnt from filling while a SWE-bench Pro run is in flight.
#
# A single up-front prune cannot work: 200 instances of ~3.7GB images need
# ~740GB and the docker disk is 492GB. Space has to be reclaimed continuously.
#
# Which safety gate applies depends on the phase, so we pick it per iteration:
#   Phase 1 -- an image is pulled strictly before its preds entry exists, so
#              "all instances present in preds.json" is enough.
#   Phase 2 -- eval re-pulls images for instances that already have preds
#              entries, so we additionally require an eval output file.
# Getting this wrong is what broke 11 instances earlier with exit 127.
set -uo pipefail
cd "$(dirname "$0")/.."

RUN_ID="${RUN_ID:?set RUN_ID}"
INTERVAL="${INTERVAL:-180}"
JOBS_ROOT="${JOBS_ROOT:-jobs}"
PREDS="$JOBS_ROOT/$RUN_ID/swebench-pro/preds/preds.json"
EVAL_DIR="$JOBS_ROOT/$RUN_ID/swebench-pro/eval"
INSTANCES="SWE-bench_Pro-os/SWE-agent/data/instances.yaml"
PYTHON=".venv-swebenchpro/bin/python"

while true; do
  if [[ -f "$PREDS" ]]; then
    gate=()
    # Only tighten to the eval gate once Phase 2 is actually running.
    # patches.json is written just before Phase 2 starts; check it too, since
    # pgrep can't see the eval process when this runs as a sibling container.
    # (On a resumed run it exists during Phase 1 as well, which only makes
    # pruning more conservative.)
    if [[ -f "$JOBS_ROOT/$RUN_ID/swebench-pro/patches.json" ]] \
        || pgrep -f "swe_bench_pro_eval\.py" >/dev/null 2>&1; then
      gate=(--eval-dir "$EVAL_DIR")
    fi
    echo "--- $(date '+%F %T') /mnt $(df -h --output=pcent /mnt | tail -1 | tr -d ' ')"
    timeout 1800 "$PYTHON" scripts/prune_done_images.py \
      --preds "$PREDS" --instances "$INSTANCES" --apply "${gate[@]}" 2>&1 | tail -2
  fi
  sleep "$INTERVAL"
done
