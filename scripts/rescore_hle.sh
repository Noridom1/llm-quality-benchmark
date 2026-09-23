#!/usr/bin/env bash
# Re-score a finished HLE run from its lm-eval response cache.
#
# The cache key is sha256(["generate_until", context, gen_kwargs]) -- it does
# not include the filter_list, so fixing an extraction regex and re-running
# with --use_cache re-scores the stored responses without a single API call.
# That only holds if the *request* is reproduced exactly: same task
# doc_to_text/process_docs, same --limit, and same gen_kwargs (in particular
# max_gen_toks, which the original run overrode from the CLI).
set -euo pipefail

cd "$(dirname "$0")/.."
WORKSPACE_DIR="$(pwd)"

set -a
source .env
set +a

export PATH="$HOME/.local/bin:$PATH"
export PYTHONPATH="$WORKSPACE_DIR/tasks/lm-eval-streaming${PYTHONPATH:+:$PYTHONPATH}"
export OPENAI_API_KEY="$API_KEY"
export HF_TOKEN="${HF_TOKEN:-}"

LM_EVAL="$WORKSPACE_DIR/.venv-lmeval/bin/lm-eval"
RAW_MODEL="${MODEL_NAME#openai/}"
ENDPOINT="${OPENAI_BASE_URL%/}/chat/completions"

RUN_ID="${RUN_ID:?set RUN_ID to the campaign whose HLE run you are re-scoring}"
SRC_DIR="$WORKSPACE_DIR/jobs/$RUN_ID/hle"
OUT_DIR="${OUT_DIR:-$WORKSPACE_DIR/jobs/$RUN_ID/hle-rescored}"
CACHE_DB="$SRC_DIR/cache.db"

# Must match the original run's effective gen_kwargs or every request misses.
LIMIT="${LIMIT:-125}"
MAX_GEN_TOKS="${MAX_GEN_TOKS:-65536}"
MAX_LENGTH="${MAX_LENGTH:-32768}"
NUM_CONCURRENT="${NUM_CONCURRENT:-6}"
REQUEST_TIMEOUT="${REQUEST_TIMEOUT:-3600}"

[[ -f "${CACHE_DB}_rank0.db" ]] || { echo "no cache at ${CACHE_DB}_rank0.db" >&2; exit 1; }
mkdir -p "$OUT_DIR"

echo "=== HLE re-score (from cache, no API calls expected) ==="
echo "  RUN_ID    : $RUN_ID"
echo "  Cache     : ${CACHE_DB}_rank0.db ($(
  sqlite3 "${CACHE_DB}_rank0.db" 'select count(*) from unnamed' 2>/dev/null || echo '?') entries)"
echo "  Output    : $OUT_DIR"
echo "  gen_kwargs: temperature=0,max_gen_toks=$MAX_GEN_TOKS  limit=$LIMIT"
echo

"$LM_EVAL" run \
  --model openai-chat-completions \
  --model_args "model=${RAW_MODEL},base_url=${ENDPOINT},tokenizer_backend=None,tokenized_requests=False,num_concurrent=${NUM_CONCURRENT},max_length=${MAX_LENGTH},timeout=${REQUEST_TIMEOUT}" \
  --tasks hle \
  --num_fewshot 0 \
  --apply_chat_template \
  --fewshot_as_multiturn \
  --batch_size 1 \
  --gen_kwargs "temperature=0,max_gen_toks=${MAX_GEN_TOKS}" \
  --include_path "$WORKSPACE_DIR/tasks" \
  --log_samples \
  --use_cache "$CACHE_DB" \
  --output_path "$OUT_DIR" \
  --limit "$LIMIT"
