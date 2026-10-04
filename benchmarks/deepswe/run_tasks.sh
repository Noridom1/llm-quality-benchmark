#!/usr/bin/env bash
# Run DeepSWE on a given list of tasks (one task per line).
#
# Use this to "continue" a missing portion: pier can only resume within the same
# job dir AND the same config (pier/job.py:196 -> FileExistsError), so a 32-task
# job cannot be extended to 64. The right approach is to run the missing part as
# a separate job and merge the results during analysis.
#
#   benchmarks/deepswe/run_tasks.sh <task-list-file> [CCU]
set -euo pipefail

cd "$(dirname "$0")/../.."
WORKSPACE_DIR="$(pwd)"

set -a
source .env
set +a

export PATH="$HOME/.local/bin:$PATH"

RAW_MODEL="${MODEL_NAME#openai/}"

# Keep the streaming patch the same as run.sh (see the comment in that script).
export PYTHONPATH="$WORKSPACE_DIR/benchmarks/deepswe/streaming${PYTHONPATH:+:$PYTHONPATH}"
MSWEA_STREAM="${MSWEA_STREAM:-1}"
export MSWEA_STREAM

TASK_FILE="${1:?usage: benchmarks/deepswe/run_tasks.sh <task-list-file> [CCU]}"
CCU="${2:-${CCU:-6}}"
RUN_ID="${RUN_ID:-$(echo "$RAW_MODEL" | tr -c '[:alnum:]._-' '_')}"
# JOBS_ROOT must be the same absolute path the host docker daemon sees:
# nested containers bind-mount subdirs of it (see docs/running-via-docker.md).
JOBS_ROOT="${JOBS_ROOT:-$WORKSPACE_DIR/jobs}"
JOBS_DIR="${JOBS_DIR:-$JOBS_ROOT/$RUN_ID/deepswe}"
JOB_NAME="${JOB_NAME:-$(basename "$TASK_FILE" .txt)-ccu${CCU}}"
MAX_GEN_TOKENS="${MAX_GEN_TOKENS:-65536}"

args=()
n=0
while IFS= read -r task || [ -n "$task" ]; do
  task="${task%%[[:space:]]*}"
  [ -z "$task" ] && continue
  if [ ! -f "deep-swe/tasks/$task/task.toml" ]; then
    echo "Task not found: $task" >&2
    exit 1
  fi
  args+=(--include-task-name "$task")
  n=$((n + 1))
done < "$TASK_FILE"

[ "$n" -gt 0 ] || { echo "Task list is empty: $TASK_FILE" >&2; exit 1; }

echo "=== DeepSWE run (task list) ==="
echo "  RUN_ID     : $RUN_ID"
echo "  Model      : $RAW_MODEL"
echo "  Task file  : $TASK_FILE ($n tasks)"
echo "  Concurrent : $CCU"
echo "  Max tokens : $MAX_GEN_TOKENS per agent turn"
echo "  Jobs dir   : $JOBS_DIR"
echo "  Job name   : $JOB_NAME"
echo

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
  --job-name "$JOB_NAME" \
  --yes
