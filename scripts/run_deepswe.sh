#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
WORKSPACE_DIR="$(pwd)"

set -a
source .env
set +a

export PATH="$HOME/.local/bin:$PATH"

# mini-swe-agent uses litellm, which expects the "openai/" provider prefix.
# Our .env stores MODEL_NAME without that prefix (lm-eval convention), so
# strip any existing prefix and re-add it.
RAW_MODEL="${MODEL_NAME#openai/}"

# Usage: run_deepswe.sh [N_TASKS] [CCU]   (CCU defaults to N_TASKS)

# Stream GLM-5.2 reasoning tokens so the connection stays alive (token frames
# reset server/LB idle timers) instead of blocking on a single buffered
# response that idle-timeouts mid-CoT. pier runs mini-swe-agent (PyPI 2.4.6)
# inside a per-task Docker container, so the local editable minisweagent patch
# used by SWE-bench Pro does NOT reach DeepSWE. This sitecustomize.py runs in
# the host pier process and monkeypatches MiniSweAgent to (1) bake an
# in-container _query streaming patch (mswea_stream_patch.py) into the image at
# install time and (2) set PYTHONPATH=/opt/mswea-stream so the container's
# mini-swe-agent auto-loads it. Disable with MSWEA_STREAM=0.
export PYTHONPATH="$WORKSPACE_DIR/tasks/deepswe-pier-streaming${PYTHONPATH:+:$PYTHONPATH}"
MSWEA_STREAM="${MSWEA_STREAM:-1}"
export MSWEA_STREAM

N_TASKS="${1:-${N_TASKS:-6}}"
CCU="${2:-${CCU:-$N_TASKS}}"
RUN_ID="${RUN_ID:-$(echo "$RAW_MODEL" | tr -c '[:alnum:]._-' '_')}"
JOBS_DIR="${JOBS_DIR:-jobs/$RUN_ID/deepswe}"
JOB_NAME="${JOB_NAME:-${N_TASKS}tasks-ccu${CCU}}"
MAX_GEN_TOKENS="${MAX_GEN_TOKENS:-32768}"

echo "=== DeepSWE run ==="
echo "  RUN_ID     : $RUN_ID"
echo "  Model      : $RAW_MODEL"
echo "  N tasks    : $N_TASKS"
echo "  Concurrent : $CCU"
echo "  Max tokens : $MAX_GEN_TOKENS per agent turn"
echo "  Jobs dir   : $JOBS_DIR"
echo

uv tool run --from datacurve-pier pier run \
  -p deep-swe/tasks \
  --agent mini-swe-agent \
  --model "openai/${RAW_MODEL}" \
  --agent-kwarg model_class=litellm \
  --agent-kwarg "model_kwargs={\"max_tokens\":${MAX_GEN_TOKENS},\"drop_params\":true}" \
  --agent-env "MSWEA_API_KEY=$API_KEY" \
  --agent-env "OPENAI_API_KEY=$API_KEY" \
  --agent-env "OPENAI_BASE_URL=$OPENAI_BASE_URL" \
  --agent-env "OPENAI_API_BASE=$OPENAI_BASE_URL" \
  --n-tasks "$N_TASKS" \
  --sample-seed 0 \
  --n-concurrent "$CCU" \
  --agent-setup-timeout-multiplier 3 \
  --jobs-dir "$JOBS_DIR" \
  --job-name "$JOB_NAME" \
  --yes
