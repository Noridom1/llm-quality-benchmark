#!/usr/bin/env bash
# Sequential General-knowledge, Balanced-tier campaign.
#   Benchmarks : GPQA -> MMLU-Pro -> HLE  (serial, one tmux pane)
#   Tier counts: 50 / 100 / 50  (quality-benchmark-recipes.md, Balanced)
#   Concurrency: NUM_CONCURRENT=2 (ccu 2) per benchmark
#
# Subset note (important): `mmlu_pro` and `hle` are lm-eval task *groups*
# (14 and 2 subtasks), so `--limit N` applies PER subtask. To hit the tier
# totals we set per-subtask limits:
#   MMLU-Pro  LIMIT=7  -> 7*14 = 98  (closest to 100 without overshoot;
#                                     LIMIT=8 would be 112. 98 is 2% under.)
#   HLE       LIMIT=25 -> 25*2 = 50  (exact)
# GPQA uses SAMPLE_N=50 (seeded random, seed 42) -- deterministic and NOT
# first-N, matching the recipe's stratified-manifest preference.
#
# Runs all three even if one fails (no -e); prints a summary at the end.
# Each sub-script has its own `set -euo pipefail` so a failure still aborts
# just that benchmark. Re-running resumes from each benchmark's SQLite cache.
set -uo pipefail

cd "$(dirname "$0")/.."
WORKSPACE_DIR="$(pwd)"

set -a; source .env; set +a
export PATH="$HOME/.local/bin:$PATH"
export OPENAI_API_KEY="$API_KEY"
export PYTHONUNBUFFERED=1

RAW_MODEL="${MODEL_NAME#openai/}"
RUN_ID="${RUN_ID:-$(echo "$RAW_MODEL" | tr -c '[:alnum:]._-' '_')}_general_balanced"
export RUN_ID

NUM_CONCURRENT=2
export NUM_CONCURRENT

LOG_DIR="jobs/$RUN_ID/logs"
mkdir -p "$LOG_DIR"
TS="$(date +%Y%m%d_%H%M%S)"
LOG="$LOG_DIR/general_balanced_${TS}.log"

# Mirror everything to the pane AND a log file.
exec > >(tee -a "$LOG") 2>&1

echo "############################################################"
echo "# General-knowledge Balanced campaign"
echo "#   RUN_ID        : $RUN_ID"
echo "#   Model         : $RAW_MODEL"
echo "#   Concurrency   : $NUM_CONCURRENT (per benchmark, serial across)"
echo "#   Counts (plan) : GPQA 50 | MMLU-Pro 98 (7x14) | HLE 50 (25x2)"
echo "#   Log           : $LOG"
echo "#   Started       : $(date -Is)"
echo "############################################################"

declare -A RESULTS=()

run_one() {
  local name="$1" cmd="$2"
  echo
  echo "============================================================"
  echo "[$name] starting $(date -Is)"
  echo "============================================================"
  if eval "$cmd"; then
    RESULTS["$name"]="OK"
  else
    RESULTS["$name"]="FAIL(rc=$?)"
  fi
  echo "[$name] -> ${RESULTS[$name]} at $(date -Is)"
}

# 1) GPQA -- 50 seeded-random samples
export SAMPLE_N=50; unset LIMIT
run_one gpqa "bash scripts/run_gpqa.sh"

# 2) MMLU-Pro -- 7 per subtask * 14 = 98 (Balanced ~100)
export LIMIT=7; unset SAMPLE_N
run_one mmlu_pro "bash scripts/run_mmlu_pro.sh"

# 3) HLE -- 25 per subtask * 2 = 50 (Balanced 50)
export LIMIT=25; unset SAMPLE_N
run_one hle "bash scripts/run_hle.sh"

echo
echo "############################################################"
echo "# Campaign summary   RUN_ID=$RUN_ID   ccu=$NUM_CONCURRENT"
echo "############################################################"
for name in gpqa mmlu_pro hle; do
  printf "  %-10s : %s\n" "$name" "${RESULTS[$name]:-SKIPPED}"
done
echo "# Log      : $LOG"
echo "# Artifacts: jobs/$RUN_ID/{gpqa,mmlu_pro,hle}/"
echo "# Finished : $(date -Is)"
echo "############################################################"
