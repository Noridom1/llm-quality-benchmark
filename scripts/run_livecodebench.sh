#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
WORKSPACE_DIR="$(pwd)"

set -a
source .env
set +a

# lcb_runner's OpenAIRunner reads OPENAI_KEY (not OPENAI_API_KEY).
# The OpenAI client picks up OPENAI_BASE_URL automatically from env.
RAW_MODEL="${MODEL_NAME#openai/}"
# Registers RAW_MODEL in lcb_runner/lm_styles.py if LCB doesn't know it yet,
# so any OpenAI-compatible model runs without patching LCB.
export LCB_MODEL="$RAW_MODEL"
export OPENAI_KEY="$API_KEY"
# OPENAI_BASE_URL is already exported by `source .env` (set -a).

LCB_DIR="$WORKSPACE_DIR/LiveCodeBench"
PYTHON="$LCB_DIR/.venv-lcb/bin/python"

# --- Run identity ------------------------------------------------------------
# RUN_ID identifies a full benchmark campaign (e.g. "gn_glm5.2").
# All benchmark artifacts land under jobs/<RUN_ID>/livecodebench/.
# Re-running with --continue_existing resumes from cached generations.
RUN_ID="${RUN_ID:-$(echo "$RAW_MODEL" | tr -c '[:alnum:]._-' '_')}"

# Defaults (overridable via env).
SCENARIO="${SCENARIO:-codegeneration}"     # codegeneration|testoutputprediction|codeexecution|selfrepair
RELEASE_VERSION="${RELEASE_VERSION:-release_latest}"
N="${N:-1}"                                # samples per problem (pass@k); pass@1 needs n>=1
TEMPERATURE="${TEMPERATURE:-0.0}"           # 0 for deterministic; LCB default is 0.2
MAX_TOKENS="${MAX_TOKENS:-${MAX_GEN_TOKENS:-65536}}"
MULTIPROCESS="${MULTIPROCESS:-4}"           # parallel API requests
TIMEOUT="${TIMEOUT:-6}"                     # eval timeout per test case (seconds)
NUM_PROCESS_EVALUATE="${NUM_PROCESS_EVALUATE:-12}"
# GLM-5.2 streams reasoning tokens, but the OpenAI SDK timeout bounds the full
# streamed generation; 90s is too tight for long CoT on hard problems.
OPENAI_TIMEOUT="${OPENAI_TIMEOUT:-600}"
LIMIT="${LIMIT:-}"                          # first N problems (smoke test)

OUT_DIR="$WORKSPACE_DIR/jobs/$RUN_ID/livecodebench"

mkdir -p "$OUT_DIR"

# LCB writes output/ and cache/ relative to CWD by default.
# We patch path_utils.py to respect LCB_OUTPUT_DIR env var so we can
# redirect artifacts to jobs/<RUN_ID>/livecodebench/ while running
# from the LCB repo directory (needed for few-shot example paths).
export LCB_OUTPUT_DIR="$OUT_DIR/"

LIMIT_ARG=()
if [[ -n "$LIMIT" ]]; then
  LIMIT_ARG=(--limit "$LIMIT")
fi

echo "=== LiveCodeBench run ==="
echo "  RUN_ID          : $RUN_ID"
echo "  Model           : $RAW_MODEL"
echo "  Scenario        : $SCENARIO"
echo "  Release version : $RELEASE_VERSION"
echo "  N (samples)     : $N"
echo "  Temperature     : $TEMPERATURE"
echo "  Max tokens      : $MAX_TOKENS"
echo "  Multiprocess    : $MULTIPROCESS"
echo "  Eval timeout    : ${TIMEOUT}s"
echo "  Output dir      : $OUT_DIR"
if [[ -n "$LIMIT" ]]; then
  echo "  Limit           : $LIMIT"
fi
echo

# Run from LCB repo dir so relative few-shot example paths resolve.
cd "$LCB_DIR"

exec "$PYTHON" -m lcb_runner.runner.main \
  --model "$RAW_MODEL" \
  --scenario "$SCENARIO" \
  --release_version "$RELEASE_VERSION" \
  --n "$N" \
  --temperature "$TEMPERATURE" \
  --max_tokens "$MAX_TOKENS" \
  --multiprocess "$MULTIPROCESS" \
  --timeout "$TIMEOUT" \
  --num_process_evaluate "$NUM_PROCESS_EVALUATE" \
  --openai_timeout "$OPENAI_TIMEOUT" \
  --evaluate \
  --use_cache \
  --continue_existing \
  "${LIMIT_ARG[@]}"
