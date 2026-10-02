#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
WORKSPACE_DIR="$(pwd)"

# Command line beats .env beats built-in default: `set -a; source .env` would
# otherwise overwrite a command-line override (VAR=x ./run_hle.sh) with the
# .env value, so snapshot and restore the ones a caller commonly overrides.
_CLI_OVERRIDES=()
for _v in MODEL_NAME RUN_ID TASK LIMIT NUM_CONCURRENT MAX_GEN_TOKS \
          HLE_MAIN_JUDGE HLE_SECOND_JUDGE HLE_SELF_JUDGE SKIP_JUDGE; do
  # "+x", not "-n": setting a knob to the empty string is a deliberate
  # override (e.g. HLE_SECOND_JUDGE= to run only one judge) and must survive
  # sourcing .env, so test whether the variable is SET, not whether it is
  # non-empty.
  if [[ -n "${!_v+x}" ]]; then
    _CLI_OVERRIDES+=("$_v=${!_v}")
  fi
done

set -a
source .env
set +a

for _kv in ${_CLI_OVERRIDES[@]+"${_CLI_OVERRIDES[@]}"}; do
  export "$_kv"
done

export PATH="$HOME/.local/bin:$PATH"

# Use the workspace venv for lm-eval.
LM_EVAL="$WORKSPACE_DIR/.venv-lmeval/bin/lm-eval"

# Stream GLM-5.2 reasoning tokens so the connection stays alive (token frames
# reset server/LB idle timers) instead of blocking on a single buffered
# response that idle-timeouts mid-CoT. The patch (a) forces stream=True in the
# payload, (b) overrides model_call/amodel_call to consume the SSE body (stock
# lm-eval 0.4.12 ignores payload["stream"] and does .json()), and (c) falls
# back to reasoning_content when content is empty. Loaded as sitecustomize.py.
# See InferenceX/utils/evals/patches/lm_eval_sitecustomize.py for the precedent.
export PYTHONPATH="$WORKSPACE_DIR/tasks/lm-eval-streaming${PYTHONPATH:+:$PYTHONPATH}"

# Explicit HTTP timeout for the streamed request (seconds). Even with streaming
# the total generation can be long for reasoning models; default 1800s mirrors
# the InferenceX HLE setting.
REQUEST_TIMEOUT="${REQUEST_TIMEOUT:-1800}"
export REQUEST_TIMEOUT

# lm-eval uses the raw model id passed to the OpenAI-compatible API.
RAW_MODEL="${MODEL_NAME#openai/}"

# Endpoint must point at the chat completions route.
ENDPOINT="${OPENAI_BASE_URL%/}/chat/completions"

# OpenAIChatCompletion reads the key from OPENAI_API_KEY, so reuse API_KEY.
export OPENAI_API_KEY="$API_KEY"

export HF_TOKEN="${HF_TOKEN:-}"

# --- Run identity ------------------------------------------------------------
RUN_ID="${RUN_ID:-$(echo "$RAW_MODEL" | tr -c '[:alnum:]._-' '_')}"

# Defaults (overridable via env).
# HLE: 2,500 expert-vetted "Google-proof" questions across 100+ subjects.
# Two answer types: exactMatch (1,909) and multipleChoice (591).
# All questions have associated images (base64); we evaluate text-only using
# the question text field, which is self-contained for many questions.
MAX_LENGTH="${MAX_LENGTH:-32768}"
MAX_GEN_TOKS="${MAX_GEN_TOKS:-${MAX_GEN_TOKENS:-65536}}"
TASK="${TASK:-hle}"
NUM_FEWSHOT="${NUM_FEWSHOT:-0}"
BATCH_SIZE="${BATCH_SIZE:-1}"
NUM_CONCURRENT="${NUM_CONCURRENT:-4}"

# Subset selection (overridable via env):
#   LIMIT=N      -> first N questions per subtask (lm-eval --limit)
#   If not set, full run (2,158 text-only questions).
LIMIT="${LIMIT:-}"

# --- Grading -----------------------------------------------------------------
# lm-eval's own `exact_match` metric is a regex extraction plus a string
# compare. Upstream HLE (github.com/centerforaisafety/hle, hle/judge.py) grades
# with an LLM judge instead, and the difference is not small: on the extended
# glm-5.2 run, exactMatch went 28.8% -> 40.0% because correct answers phrased
# differently from the target string were scored wrong. The lm-eval table this
# script prints is therefore a FLOOR, not the score. So judge by default, and
# report the judged number.
#
# Three judges run over the same cached responses (generation is not repeated,
# so this costs judge tokens only):
#
#   HLE_MAIN_JUDGE   - produces the score. Must be independent of the model.
#   HLE_SECOND_JUDGE - independent cross-check. Its job is to show the score is
#                      not an artefact of the main judge; set empty to skip.
#   HLE_SELF_JUDGE   - the model under test grading itself, to measure
#                      self-judging bias. NEVER a number to report. Set 0 to
#                      skip; it is the slowest of the three (glm-5.2 took 875s
#                      vs deepseek's 307s on 250 docs) and the likeliest to
#                      leave verdicts unparseable.
SKIP_JUDGE="${SKIP_JUDGE:-0}"
HLE_MAIN_JUDGE="${HLE_MAIN_JUDGE:-deepseek/deepseek-v4-pro}"
# ${VAR-default}, not ${VAR:-default}: an explicit HLE_SECOND_JUDGE= means
# "no second judge", and must not fall back to the default.
HLE_SECOND_JUDGE="${HLE_SECOND_JUDGE-qwen/qwen3.7-plus}"
HLE_SELF_JUDGE="${HLE_SELF_JUDGE:-1}"

OUT_DIR="$WORKSPACE_DIR/jobs/$RUN_ID/hle"
CACHE_DB="$OUT_DIR/cache.db"
TASKS_DIR="$WORKSPACE_DIR/tasks"

mkdir -p "$OUT_DIR"

# Build subset args for lm-eval
SUBSET_ARGS=()
if [[ -n "$LIMIT" ]]; then
  SUBSET_ARGS=(--limit "$LIMIT")
fi

echo "=== HLE (Humanity's Last Exam) run ==="
echo "  RUN_ID        : $RUN_ID"
echo "  Model         : $RAW_MODEL"
echo "  Task          : $TASK"
echo "  Max gen tokens: $MAX_GEN_TOKS"
echo "  Output dir    : $OUT_DIR"
echo "  Cache (resume): $CACHE_DB"
if [[ -n "$LIMIT" ]]; then
  echo "  Subset        : first ${LIMIT} per subtask"
fi
if [[ "$SKIP_JUDGE" == "1" ]]; then
  echo "  Grading       : lm-eval string match only (SKIP_JUDGE=1)"
else
  echo "  Grading       : lm-eval string match, then LLM judge"
  echo "  Main judge    : $HLE_MAIN_JUDGE (produces the score)"
  echo "  Second judge  : ${HLE_SECOND_JUDGE:-(none)}"
  if [[ "$HLE_SELF_JUDGE" == "1" ]]; then
    echo "  Self judge    : $RAW_MODEL (bias check, not a score)"
  fi
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
  --include_path "$TASKS_DIR" \
  --log_samples \
  --use_cache "$CACHE_DB" \
  --output_path "$OUT_DIR" \
  "${SUBSET_ARGS[@]}"

# --- LLM judge ---------------------------------------------------------------
if [[ "$SKIP_JUDGE" == "1" ]]; then
  echo
  echo "NOTE: skipped the LLM judge (SKIP_JUDGE=1). The lm-eval table above is a"
  echo "      string-match floor, not the HLE score. Judge it later with:"
  echo "        RUN_ID=$RUN_ID SRC_SUBDIR=hle ./scripts/judge_hle.sh"
  exit 0
fi

# A judge that is the model under test cannot produce the score. If that is how
# the main judge is configured, promote the second judge rather than either
# self-judging or silently reporting nothing.
if [[ "$HLE_MAIN_JUDGE" == "$RAW_MODEL" ]]; then
  if [[ -n "$HLE_SECOND_JUDGE" && "$HLE_SECOND_JUDGE" != "$RAW_MODEL" ]]; then
    echo
    echo "NOTE: main judge is the model under test ($RAW_MODEL);"
    echo "      promoting the second judge ($HLE_SECOND_JUDGE) to main."
    HLE_MAIN_JUDGE="$HLE_SECOND_JUDGE"
    HLE_SECOND_JUDGE=""
  else
    echo "ERROR: HLE_MAIN_JUDGE ($HLE_MAIN_JUDGE) is the model under test and there" >&2
    echo "       is no independent second judge to promote. Set HLE_MAIN_JUDGE to a" >&2
    echo "       different model." >&2
    exit 2
  fi
fi

# Build the judge list. The self-judge is run through the same path with
# ALLOW_SELF_JUDGE=1; it is recorded and compared, but never reported.
JUDGES=("$HLE_MAIN_JUDGE")
if [[ -n "$HLE_SECOND_JUDGE" && "$HLE_SECOND_JUDGE" != "$HLE_MAIN_JUDGE" ]]; then
  JUDGES+=("$HLE_SECOND_JUDGE")
fi
SELF_JUDGE_ARG=()
if [[ "$HLE_SELF_JUDGE" == "1" ]]; then
  if [[ "$RAW_MODEL" == "$HLE_MAIN_JUDGE" || "$RAW_MODEL" == "${HLE_SECOND_JUDGE:-}" ]]; then
    echo
    echo "NOTE: the model under test is already one of the judges; skipping the"
    echo "      separate self-judge pass."
  else
    JUDGES+=("$RAW_MODEL")
    SELF_JUDGE_ARG=(--self-judge "$RAW_MODEL")
  fi
fi

# Grade this run's own samples (jobs/<RUN_ID>/hle), not the default
# hle-rescored/ directory. Judge failures must not fail the run: generation is
# the expensive part and it is already on disk, and every judge is resumable
# from the shared verdict cache, so a re-run costs nothing for what succeeded.
judge_failures=0
for judge in "${JUDGES[@]}"; do
  echo
  if [[ "$judge" == "$RAW_MODEL" ]]; then
    echo "=== Judge: $judge (SELF-JUDGE -- bias check, not a score) ==="
    allow_self=1
  else
    echo "=== Judge: $judge ==="
    allow_self=0
  fi
  if ! RUN_ID="$RUN_ID" SRC_SUBDIR="hle" JUDGE_MODEL="$judge" \
       ALLOW_SELF_JUDGE="$allow_self" "$WORKSPACE_DIR/scripts/judge_hle.sh"; then
    echo "WARNING: judge $judge failed; continuing with the remaining judges." >&2
    judge_failures=$((judge_failures + 1))
    if [[ "$judge" == "$HLE_MAIN_JUDGE" ]]; then
      echo "         This was the MAIN judge -- there is no score for this run yet." >&2
    fi
  fi
done

SECOND_JUDGE_ARG=()
if [[ -n "$HLE_SECOND_JUDGE" && "$HLE_SECOND_JUDGE" != "$HLE_MAIN_JUDGE" ]]; then
  SECOND_JUDGE_ARG=(--judge "$HLE_SECOND_JUDGE")
fi

"$WORKSPACE_DIR/.venv-lmeval/bin/python" "$WORKSPACE_DIR/scripts/compare_judges.py" \
  --dir "$WORKSPACE_DIR/jobs/$RUN_ID/hle-judged" \
  --main-judge "$HLE_MAIN_JUDGE" \
  ${SECOND_JUDGE_ARG[@]+"${SECOND_JUDGE_ARG[@]}"} \
  ${SELF_JUDGE_ARG[@]+"${SELF_JUDGE_ARG[@]}"} || true

if [[ "$judge_failures" != "0" ]]; then
  echo
  echo "WARNING: $judge_failures judge(s) failed. Responses are intact under $OUT_DIR;"
  echo "         re-run a single judge with:"
  echo "           RUN_ID=$RUN_ID SRC_SUBDIR=hle JUDGE_MODEL=<model> ./scripts/judge_hle.sh"
  exit 1
fi
