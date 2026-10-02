#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
WORKSPACE_DIR="$(pwd)"

set -a
source .env
set +a

export PATH="$WORKSPACE_DIR/.venv-scicode/bin:$HOME/.local/bin:$PATH"

RAW_MODEL="${MODEL_NAME#openai/}"
export OPENAI_API_KEY="$API_KEY"

INSPECT="$WORKSPACE_DIR/.venv-scicode/bin/inspect"

RUN_ID="${RUN_ID:-$(echo "$RAW_MODEL" | tr -c '[:alnum:]._-' '_')}"
OUT_DIR="$WORKSPACE_DIR/jobs/$RUN_ID/scicode"
LOG_DIR="$OUT_DIR/logs"

MAX_CONNECTIONS="${MAX_CONNECTIONS:-4}"
MAX_TOKENS="${MAX_TOKENS:-${MAX_GEN_TOKENS:-65536}}"
RETRY_ON_ERROR="${RETRY_ON_ERROR:-2}"

cd "$WORKSPACE_DIR/SciCode/eval/inspect_ai"

# Find the most recent .eval log for this RUN_ID.
LAST_LOG=$(ls -t "$LOG_DIR"/*.eval 2>/dev/null | head -1)
if [[ -z "$LAST_LOG" ]]; then
  echo "No .eval log found in $LOG_DIR — nothing to retry." >&2
  exit 1
fi

echo "=== SciCode retry ==="
echo "  RUN_ID        : $RUN_ID"
echo "  Resuming from : $LAST_LOG"
echo

"$INSPECT" eval-retry "$LAST_LOG" \
  --max-connections "$MAX_CONNECTIONS" \
  --max-tokens "$MAX_TOKENS" \
  --retry-on-error "$RETRY_ON_ERROR" \
  --no-fail-on-error \
  --continue-on-fail \
  --log-dir "$LOG_DIR" \
  --metadata "run_id=${RUN_ID}"
