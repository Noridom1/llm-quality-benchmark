#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/../.."
WORKSPACE_DIR="$(pwd)"

set -a
source .env
set +a

export PATH="$HOME/.local/bin:$PATH"

# Use the workspace venv for lm-eval.
LM_EVAL="$WORKSPACE_DIR/.venv-lmeval/bin/lm-eval"

# Stream GLM-5.2 reasoning tokens so the connection stays alive (token frames
# reset server/LB idle timers) instead of blocking on a single buffered
# response that idle-timeouts mid-CoT. The patch (a) forces stream=True in the
# payload, (b) overrides model_call/amodel_call to consume the SSE body (stock
# lm-eval 0.4.12 ignores payload["stream"] and does .json()), and (c) falls
# back to reasoning_content when content is empty. Loaded as sitecustomize.py.
export PYTHONPATH="$WORKSPACE_DIR/benchmarks/_shared/lm-eval-streaming${PYTHONPATH:+:$PYTHONPATH}"

# Explicit HTTP timeout for the streamed request (seconds). Even with streaming
# the total generation can be long for reasoning models; default 1800s.
REQUEST_TIMEOUT="${REQUEST_TIMEOUT:-1800}"
export REQUEST_TIMEOUT

# lm-eval uses the raw model id passed to the OpenAI-compatible API.
# Our .env stores it as "openai/<provider>/<model>"; strip the leading "openai/".
RAW_MODEL="${MODEL_NAME#openai/}"

# Endpoint must point at the chat completions route.
ENDPOINT="${OPENAI_BASE_URL%/}/chat/completions"

# OpenAIChatCompletion reads the key from OPENAI_API_KEY, so reuse API_KEY.
export OPENAI_API_KEY="$API_KEY"

export HF_TOKEN="${HF_TOKEN:-}"

# --- Run identity ------------------------------------------------------------
# RUN_ID identifies a full benchmark campaign (e.g. "gn_glm5.2").
# All benchmark artifacts land under jobs/<RUN_ID>/<benchmark>/.
# Re-running with the same RUN_ID resumes via the SQLite cache: prompts already
# answered are skipped, only failed/missing ones hit the endpoint.
RUN_ID="${RUN_ID:-$(echo "$RAW_MODEL" | tr -c '[:alnum:]._-' '_')}"

# Defaults (overridable via env): context window, generation length, task, few-shot, concurrency.
# MMLU-Pro: 12,032 questions, 14 disciplines, 10 options, standard protocol is 5-shot CoT.
MAX_LENGTH="${MAX_LENGTH:-8192}"
MAX_GEN_TOKS="${MAX_GEN_TOKS:-${MAX_GEN_TOKENS:-65536}}"
TASK="${TASK:-mmlu_pro}"
NUM_FEWSHOT="${NUM_FEWSHOT:-5}"
BATCH_SIZE="${BATCH_SIZE:-1}"
NUM_CONCURRENT="${NUM_CONCURRENT:-4}"

# Subset selection (overridable via env):
#   LIMIT=N      -> first N questions per subtask (lm-eval --limit)
#   If neither set, full run (12,032 questions across 14 subtasks).
LIMIT="${LIMIT:-}"

OUT_DIR="$WORKSPACE_DIR/jobs/$RUN_ID/mmlu_pro"
CACHE_DB="$OUT_DIR/cache.db"

mkdir -p "$OUT_DIR"

# Build subset args for lm-eval
SUBSET_ARGS=()
if [[ -n "$LIMIT" ]]; then
  SUBSET_ARGS=(--limit "$LIMIT")
fi

echo "=== MMLU-Pro run ==="
echo "  RUN_ID        : $RUN_ID"
echo "  Model         : $RAW_MODEL"
echo "  Task          : $TASK"
echo "  Max gen tokens: $MAX_GEN_TOKS"
echo "  Output dir    : $OUT_DIR"
echo "  Cache (resume): $CACHE_DB"
if [[ -n "$LIMIT" ]]; then
  echo "  Subset        : first ${LIMIT} per subtask"
fi
echo

"$LM_EVAL" run \
  --model openai-chat-completions \
  --model_args "model=${RAW_MODEL},base_url=${ENDPOINT},tokenizer_backend=None,tokenized_requests=False,num_concurrent=${NUM_CONCURRENT},max_length=${MAX_LENGTH},timeout=${REQUEST_TIMEOUT}" \
  --tasks "$TASK" \
  --num_fewshot "$NUM_FEWSHOT" \
  --apply_chat_template \
  --batch_size "$BATCH_SIZE" \
  --gen_kwargs "temperature=0,max_gen_toks=${MAX_GEN_TOKS}" \
  --log_samples \
  --use_cache "$CACHE_DB" \
  --output_path "$OUT_DIR" \
  "${SUBSET_ARGS[@]}"
