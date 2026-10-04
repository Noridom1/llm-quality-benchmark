#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/../.."
WORKSPACE_DIR="$(pwd)"

set -a
source .env
set +a

export PATH="$HOME/.local/bin:$PATH"

# mini-swe-agent uses litellm, which expects the "openai/" provider prefix.
# Our .env stores MODEL_NAME without that prefix (lm-eval convention), so
# strip any existing prefix and re-add it.
RAW_MODEL="${MODEL_NAME#openai/}"

# Stream GLM-5.2 reasoning tokens so the connection stays alive (token frames
# reset server/LB idle timers) instead of blocking on a single buffered
# response that idle-timeouts mid-CoT. See benchmarks/deepswe/run.sh for full
# details. This sitecustomize.py runs in the host pier process and
# monkeypatches MiniSweAgent to bake an in-container _query streaming patch
# into the image at install time and set PYTHONPATH=/opt/mswea-stream so the
# container's mini-swe-agent auto-loads it. Disable with MSWEA_STREAM=0.
export PYTHONPATH="$WORKSPACE_DIR/benchmarks/deepswe/streaming${PYTHONPATH:+:$PYTHONPATH}"
MSWEA_STREAM="${MSWEA_STREAM:-1}"
export MSWEA_STREAM

BATCH_SIZE="${BATCH_SIZE:-20}"
CCU="${CCU:-6}"
MAX_TASKS="${MAX_TASKS:-113}"
RUN_ID="${RUN_ID:-$(echo "$RAW_MODEL" | tr -c '[:alnum:]._-' '_')}"
# JOBS_ROOT must be the same absolute path the host docker daemon sees:
# nested containers bind-mount subdirs of it (see docs/running-via-docker.md).
JOBS_ROOT="${JOBS_ROOT:-$WORKSPACE_DIR/jobs}"
JOBS_DIR="${JOBS_DIR:-$JOBS_ROOT/$RUN_ID/deepswe-batches}"
BATCH_DIR="${BATCH_DIR:-task_batches}"
PRUNE_DOCKER_AFTER_BATCH="${PRUNE_DOCKER_AFTER_BATCH:-0}"
DOCKER_IMAGE_PRUNE_UNTIL="${DOCKER_IMAGE_PRUNE_UNTIL:-2h}"
MAX_GEN_TOKENS="${MAX_GEN_TOKENS:-65536}"

cleanup_after_batch() {
  if [ "$PRUNE_DOCKER_AFTER_BATCH" != "1" ]; then
    return
  fi

  if ! command -v docker >/dev/null 2>&1; then
    echo "Skip Docker cleanup: docker not found"
    return
  fi

  echo "Docker cleanup: stopped containers and unused images older than $DOCKER_IMAGE_PRUNE_UNTIL"
  docker container prune -f || echo "Warning: docker container prune failed"
  docker image prune -af --filter "until=$DOCKER_IMAGE_PRUNE_UNTIL" || echo "Warning: docker image prune failed"
  docker system df || true
}

rm -rf "$BATCH_DIR"
mkdir -p "$BATCH_DIR"

find deep-swe/tasks -mindepth 1 -maxdepth 1 -type d -exec basename {} \; \
  | sort \
  | grep -v '^ugc-' \
  | head -n "$MAX_TASKS" \
  | awk -v n="$BATCH_SIZE" -v dir="$BATCH_DIR" '{ f=sprintf("%s/batch_%02d.txt", dir, int((NR-1)/n)); print > f }'

total="$(cat "$BATCH_DIR"/batch_*.txt | wc -l | tr -d ' ')"
if [ "$total" -ne "$MAX_TASKS" ]; then
  echo "Expected $MAX_TASKS tasks, got $total"
  exit 1
fi

echo "=== DeepSWE batched run ==="
echo "  RUN_ID      : $RUN_ID"
echo "  Model       : $RAW_MODEL"
echo "  Max tasks   : $MAX_TASKS"
echo "  Batch size  : $BATCH_SIZE"
echo "  Concurrent  : $CCU"
echo "  Max tokens  : $MAX_GEN_TOKENS per agent turn"
echo "  Jobs dir    : $JOBS_DIR"
echo

for batch in "$BATCH_DIR"/batch_*.txt; do
  name="$(basename "$batch" .txt)"

  if [ -f "$JOBS_DIR/$name/result.json" ]; then
    echo "Skip finished $name"
    continue
  fi

  args=()
  while IFS= read -r task; do
    args+=(--include-task-name "$task")
  done < "$batch"

  uv tool run --from datacurve-pier pier run \
    -p deep-swe/tasks \
    "${args[@]}" \
    --agent mini-swe-agent \
    --model "openai/${RAW_MODEL}" \
    --agent-kwarg model_class=litellm \
    --agent-kwarg "model_kwargs={\"max_tokens\":${MAX_GEN_TOKENS},\"drop_params\":true}" \
    --agent-env "MSWEA_API_KEY=$API_KEY" \
    --agent-env "OPENAI_API_KEY=$API_KEY" \
    --agent-env "OPENAI_BASE_URL=$OPENAI_BASE_URL" \
    --agent-env "OPENAI_API_BASE=$OPENAI_BASE_URL" \
    --n-concurrent "$CCU" \
    --agent-setup-timeout-multiplier 3 \
    --jobs-dir "$JOBS_DIR" \
    --job-name "$name" \
    --yes

  cleanup_after_batch
done
