#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
WORKSPACE_DIR="$(pwd)"

set -a
source .env
set +a

# The SciCode scorer runs generated code via subprocess(['python', ...]),
# so the venv's python must be first on PATH (for numpy/scipy/etc.).
export PATH="$WORKSPACE_DIR/.venv-scicode/bin:$HOME/.local/bin:$PATH"

# inspect_ai uses litellm under the hood for openai/* models.
# Strip any leading "openai/" from MODEL_NAME, then re-add it so litellm
# routes to the OpenAI-compatible provider.
RAW_MODEL="${MODEL_NAME#openai/}"

# litellm reads OPENAI_API_KEY and OPENAI_BASE_URL from env.
export OPENAI_API_KEY="$API_KEY"
# OPENAI_BASE_URL is already exported by `source .env` (set -a).

SCICODE_DIR="SciCode"
INSPECT="$WORKSPACE_DIR/.venv-scicode/bin/inspect"

# Stream GLM-5.2 reasoning tokens so the connection stays alive (token frames
# reset server/LB idle timers) instead of blocking on a single buffered
# response that idle-timeouts mid-CoT. SciCode can generate long responses, so the
# total generation can be long. The patch reimplements inspect's
# generate_completions direct path to request stream=True and accumulate the
# AsyncStream into a ChatCompletion (the batcher path falls back to
# non-streaming). Loaded as sitecustomize.py. Disable with INSPECT_STREAM=0.
export PYTHONPATH="$WORKSPACE_DIR/tasks/inspect-streaming${PYTHONPATH:+:$PYTHONPATH}"

# Client timeout (seconds) for the streamed generation. Even with streaming the
# total time-to-last-token can be long; inspect's OpenAI provider reads this
# via the client_timeout model arg. Default 1800s.
INSPECT_CLIENT_TIMEOUT="${INSPECT_CLIENT_TIMEOUT:-1800}"

# --- Run identity ------------------------------------------------------------
# RUN_ID identifies a full benchmark campaign (e.g. "gn_glm5.2").
# All benchmark artifacts land under jobs/<RUN_ID>/<benchmark>/.
# Re-running with the same RUN_ID + inspect eval-retry resumes failed samples.
RUN_ID="${RUN_ID:-$(echo "$RAW_MODEL" | tr -c '[:alnum:]._-' '_')}"

# Defaults (overridable via env): split, background, concurrency, tokens, output.
SPLIT="${SPLIT:-test}"                   # validation (15) or test (65)
WITH_BACKGROUND="${WITH_BACKGROUND:-False}"
MAX_CONNECTIONS="${MAX_CONNECTIONS:-4}"
MAX_TOKENS="${MAX_TOKENS:-${MAX_GEN_TOKENS:-16384}}"
LIMIT="${LIMIT:-}"
SAMPLE_SHUFFLE="${SAMPLE_SHUFFLE:-}"

# Retry-on-error: retry each failed sample this many times before marking error.
RETRY_ON_ERROR="${RETRY_ON_ERROR:-2}"

OUT_DIR="$WORKSPACE_DIR/jobs/$RUN_ID/scicode"
# inspect_ai writes its own .eval binary logs here; eval-retry reads from here.
LOG_DIR="$OUT_DIR/logs"

mkdir -p "$OUT_DIR" "$LOG_DIR"

LIMIT_ARG=()
if [[ -n "$LIMIT" ]]; then
  LIMIT_ARG=(--limit "$LIMIT")
fi

SHUFFLE_ARG=()
if [[ -n "$SAMPLE_SHUFFLE" ]]; then
  SHUFFLE_ARG=(--sample-shuffle "$SAMPLE_SHUFFLE")
fi

cd "$SCICODE_DIR/eval/inspect_ai"

echo "=== SciCode run ==="
echo "  RUN_ID        : $RUN_ID"
echo "  Model         : $RAW_MODEL"
echo "  Split         : $SPLIT"
echo "  Output dir    : $OUT_DIR"
echo "  Log dir       : $LOG_DIR"
echo "  Max tokens    : $MAX_TOKENS"
echo "  Retry on error: $RETRY_ON_ERROR"
if [[ -n "$LIMIT" ]]; then
  echo "  Limit         : $LIMIT"
fi
if [[ -n "$SAMPLE_SHUFFLE" ]]; then
  echo "  Sample shuffle: seed=$SAMPLE_SHUFFLE"
fi
echo

# get_model() always splits the model string on the FIRST "/" and treats that
# segment as the provider name (inspect_ai/model/_model.py resolve_model), for
# every provider, not just azure/bedrock. Passing the bare model (no "openai/"
# prefix) makes inspect read provider="z-ai" (unregistered) and crash with
# "Model API z-ai ... not recognized." So we must prepend "openai/"; inspect
# strips it before constructing OpenAIAPI, so the wire payload still gets the
# bare "z-ai/glm-5.2" model id.
#
# --model is NOT "model,key=val,..." -- resolve_models() does model.split(",")
# on the whole string to support multi-model eval, so a second "part" like
# "client_timeout=1800" is parsed as its own model name and fails the same
# <api_name>/<model_name> check. Model kwargs must go through -M (one per
# flag), which parse_cli_config() merges into get_model()'s **model_args.
# Force responses_api=False via -M: this explicit arg overrides OpenAIAPI's
# is_latest_model()-based auto-detection regardless of prefix, keeping us on
# /v1/chat/completions (which this endpoint supports and where the streaming
# patch, sitecustomize.py, hooks in) instead of the unsupported /v1/responses.
"$INSPECT" eval scicode.py \
  --model "openai/${RAW_MODEL}" \
  -M "client_timeout=${INSPECT_CLIENT_TIMEOUT}" \
  -M "responses_api=False" \
  --temperature 0 \
  --max-connections "$MAX_CONNECTIONS" \
  --max-tokens "$MAX_TOKENS" \
  --log-dir "$LOG_DIR" \
  --retry-on-error "$RETRY_ON_ERROR" \
  --no-fail-on-error \
  --continue-on-fail \
  --metadata "run_id=${RUN_ID}" \
  "${LIMIT_ARG[@]}" \
  "${SHUFFLE_ARG[@]}" \
  -T split="$SPLIT" \
  -T output_dir="$OUT_DIR" \
  -T with_background="$WITH_BACKGROUND" \
  -T h5py_file="../data/test_data.h5" \
  -T mode=normal
