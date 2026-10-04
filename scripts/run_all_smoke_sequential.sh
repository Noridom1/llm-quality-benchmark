#!/usr/bin/env bash
# Sequential smoke-run driver for all 8 benchmarks under a single RUN_ID.
# Runs ONE benchmark at a time to avoid API rate-limit (429) contention.
# The API has a tight ~25 RPM limit, so each lm-eval benchmark runs with
# NUM_CONCURRENT=1 and is wrapped in a generous retry loop that resumes from
# its SQLite cache (only failed/missing prompts are re-sent on retry).
set -uo pipefail

cd "$(dirname "$0")/.."
RUN_ID="${RUN_ID:-full-bmk-smoke}"
LOG_DIR="logs/$RUN_ID"
mkdir -p "$LOG_DIR"

# run_with_retry NAME MAX_ATTEMPTS COOLDOWN_SECS -- CMD...
# Runs CMD; on failure waits COOLDOWN_SECS and retries. CMD's stdout/stderr go
# to the per-benchmark log via the caller-supplied redirection *inside* CMD,
# while this function's own status lines go to the driver log (stdout).
run_with_retry() {
  local name="$1"; shift
  local max_attempts="$1"; shift
  local cooldown="$1"; shift
  # Drop an explicit "--" separator if present.
  if [[ "${1:-}" == "--" ]]; then shift; fi
  local attempt=0
  while (( attempt < max_attempts )); do
    attempt=$((attempt + 1))
    echo "===== [$name] attempt $attempt/$max_attempts ($(date)) ====="
    if "$@"; then
      echo "===== [$name] OK ====="
      return 0
    fi
    echo "===== [$name] attempt $attempt failed; cooling down ${cooldown}s ====="
    sleep "$cooldown"
  done
  echo "===== [$name] FAILED after $max_attempts attempts ====="
  return 1
}

echo "RUN_ID=$RUN_ID  starting sequential smoke at $(date)"

# 1. GPQA
run_with_retry gpqa 8 30 -- env RUN_ID="$RUN_ID" LIMIT=4 NUM_CONCURRENT=1 \
  bash benchmarks/gpqa/run.sh > "$LOG_DIR/gpqa.log" 2>&1

# 2. MMLU-Pro
run_with_retry mmlu_pro 30 60 -- env RUN_ID="$RUN_ID" LIMIT=4 NUM_CONCURRENT=1 \
  bash benchmarks/mmlu_pro/run.sh > "$LOG_DIR/mmlu_pro.log" 2>&1

# 3. HLE
run_with_retry hle 30 60 -- env RUN_ID="$RUN_ID" LIMIT=4 NUM_CONCURRENT=1 \
  bash benchmarks/hle/run.sh > "$LOG_DIR/hle.log" 2>&1

# 4. LiveCodeBench
run_with_retry livecodebench 8 30 -- env RUN_ID="$RUN_ID" LIMIT=4 MULTIPROCESS=1 \
  bash benchmarks/livecodebench/run.sh > "$LOG_DIR/livecodebench.log" 2>&1

# 5. BFCL (default AST categories)
run_with_retry bfcl 8 30 -- env RUN_ID="$RUN_ID" NUM_THREADS=1 \
  bash benchmarks/bfcl/run.sh > "$LOG_DIR/bfcl.log" 2>&1

# 6. SciCode
run_with_retry scicode 8 30 -- env RUN_ID="$RUN_ID" LIMIT=2 SPLIT=validation MAX_CONNECTIONS=1 \
  bash benchmarks/scicode/run.sh > "$LOG_DIR/scicode.log" 2>&1

# 7. SWE-bench Pro
run_with_retry swebench_pro 8 30 -- env RUN_ID="$RUN_ID" LIMIT=4 WORKERS=1 \
  bash benchmarks/swebench_pro/run.sh > "$LOG_DIR/swebench_pro.log" 2>&1

# 8. DeepSWE
run_with_retry deepswe 8 30 -- env RUN_ID="$RUN_ID" N_TASKS=1 CCU=1 \
  bash benchmarks/deepswe/run.sh > "$LOG_DIR/deepswe.log" 2>&1

echo "All sequential smoke runs finished at $(date)"
