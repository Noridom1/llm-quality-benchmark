#!/usr/bin/env bash
# Chạy DeepSWE trên một danh sách task cho trước (1 task / dòng).
#
# Dùng khi cần "chạy tiếp" phần còn thiếu: pier chỉ resume được trong cùng một
# job dir VÀ cùng config (pier/job.py:196 -> FileExistsError), nên không thể mở
# rộng một job 32 task thành 64. Cách đúng là chạy phần thiếu thành job riêng
# rồi gộp kết quả khi phân tích.
#
#   scripts/run_deepswe_tasks.sh <file-danh-sach> [CCU]
set -euo pipefail

cd "$(dirname "$0")/.."
WORKSPACE_DIR="$(pwd)"

set -a
source .env
set +a

export PATH="$HOME/.local/bin:$PATH"

RAW_MODEL="${MODEL_NAME#openai/}"

# Giữ patch streaming giống run_deepswe.sh (xem comment ở script đó).
export PYTHONPATH="$WORKSPACE_DIR/tasks/deepswe-pier-streaming${PYTHONPATH:+:$PYTHONPATH}"
MSWEA_STREAM="${MSWEA_STREAM:-1}"
export MSWEA_STREAM

TASK_FILE="${1:?usage: run_deepswe_tasks.sh <task-list-file> [CCU]}"
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
    echo "Không tìm thấy task: $task" >&2
    exit 1
  fi
  args+=(--include-task-name "$task")
  n=$((n + 1))
done < "$TASK_FILE"

[ "$n" -gt 0 ] || { echo "Danh sách task rỗng: $TASK_FILE" >&2; exit 1; }

echo "=== DeepSWE run (task list) ==="
echo "  RUN_ID     : $RUN_ID"
echo "  Model      : $RAW_MODEL"
echo "  Task file  : $TASK_FILE ($n task)"
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
