#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/../.."
WORKSPACE_DIR="$(pwd)"

set -a
source .env
set +a

# lm-eval-style: .env stores MODEL_NAME as "openai/<provider>/<model>"; strip the leading "openai/".
RAW_MODEL="${MODEL_NAME#openai/}"
# Registers "<RAW_MODEL>-FC"/"-PROMPT" in bfcl_eval/constants/model_config.py
# if BFCL doesn't know them yet, so any OpenAI-compatible model runs without
# patching BFCL.
export BFCL_MODEL="$RAW_MODEL"

# --- BFCL harness paths ------------------------------------------------------
BFCL_DIR="$WORKSPACE_DIR/BFCL/berkeley-function-call-leaderboard"
PYTHON="$BFCL_DIR/.venv-bfcl/bin/python"
BFCL="$BFCL_DIR/.venv-bfcl/bin/bfcl"

# --- Run identity ------------------------------------------------------------
RUN_ID="${RUN_ID:-$(echo "$RAW_MODEL" | tr -c '[:alnum:]._-' '_')}"
OUT_DIR="$WORKSPACE_DIR/jobs/$RUN_ID/bfcl"
mkdir -p "$OUT_DIR"

# BFCL resolves all paths (result/, score/, .env, .file_locks/) from
# BFCL_PROJECT_ROOT. Redirecting it keeps artifacts under jobs/<RUN_ID>/bfcl/
# and stops the harness from writing into the source tree.
export BFCL_PROJECT_ROOT="$OUT_DIR"

# The bfcl CLI force-loads $BFCL_PROJECT_ROOT/.env with override=True, which
# would clobber any exported OPENAI_* vars. We write the creds we want into
# that .env so BFCL's own load_dotenv picks them up deterministically.
# OPENAICompletionsHandler._build_client_kwargs() reads OPENAI_API_KEY +
# OPENAI_BASE_URL straight from the environment.
cat > "$OUT_DIR/.env" <<EOF
OPENAI_API_KEY=${API_KEY}
OPENAI_BASE_URL=${OPENAI_BASE_URL}
EOF

# --- Mode selection ----------------------------------------------------------
# BFCL has two function-calling modes, set as a property of the ModelConfig
# entry (not a CLI flag):
#   FC     -> is_fc_model=True:  sends OpenAI `tools=[...]`, parses `tool_calls`.
#                                   Requires the endpoint to natively support
#                                   OpenAI-style tool calling. Best accuracy.
#   PROMPT -> is_fc_model=False: functions stringified into a system prompt;
#                                   the model emits text, BFCL parses it.
#                                   Fallback for text-only endpoints.
# Both keys, "<RAW_MODEL>-FC" and "<RAW_MODEL>-PROMPT", exist for any model:
# hand-written in bfcl_eval/constants/model_config.py for GLM-5.2 / Gemma-4,
# registered at import from BFCL_MODEL (exported above) for everything else.
BFCL_MODE="${BFCL_MODE:-FC}"   # FC | PROMPT
case "$BFCL_MODE" in
  FC)     BFCL_MODEL_KEY="${RAW_MODEL}-FC" ;;
  PROMPT) BFCL_MODEL_KEY="${RAW_MODEL}-PROMPT" ;;
  *) echo "BFCL_MODE must be FC or PROMPT (got: $BFCL_MODE)" >&2; exit 1 ;;
esac

# --- Defaults (overridable via env) -----------------------------------------
# Smoke-friendly default: pure-AST categories, no network, no SerpAPI, no Docker.
#   simple_python  multiple  parallel  parallel_multiple  irrelevance
# Expand to a full run with TEST_CATEGORY=all_scoring (excludes the
# non-scoring format_sensitivity), or TEST_CATEGORY=all for everything.
# Add web_search,memory for v4 agentic coverage (web_search needs SERPAPI_API_KEY).
TEST_CATEGORY="${TEST_CATEGORY:-simple_python,multiple,parallel,parallel_multiple,irrelevance}"
NUM_THREADS="${NUM_THREADS:-4}"
TEMPERATURE="${TEMPERATURE:-0.0}"    # BFCL default 0.001; 0 for determinism
export MAX_GEN_TOKENS="${MAX_GEN_TOKENS:-65536}"
# BFCL shares the OpenAI client default timeout; bump for slow endpoints.
# GLM-5.2 streams reasoning tokens, but the OpenAI SDK timeout bounds the full
# streamed generation; 90s is too tight for long CoT on tool-calling prompts.
export OPENAI_TIMEOUT="${OPENAI_TIMEOUT:-600}"

# Phase 2 (evaluate) needs --partial-eval whenever Phase 1 ran a subset
# (fewer categories, or --run-ids). With the default smoke categories it is
# required because we are not running the full `all` set.
PARTIAL_EVAL_FLAG="--partial-eval"
if [[ "${FULL_EVAL:-0}" == "1" ]]; then
  PARTIAL_EVAL_FLAG=""
fi

# --- Optional: restrict to a handful of test-case IDs -----------------------
# If TEST_CASE_IDS is set (e.g. 'simple_python: ["simple_python_102"]' as JSON,
# or a path to such a file), copy it to $BFCL_PROJECT_ROOT/test_case_ids_to_generate.json
# and add --run-ids to generation. See bfcl_eval/test_case_ids_to_generate.json.example.
RUN_IDS_ARG=()
if [[ -n "${TEST_CASE_IDS:-}" ]]; then
  IDS_FILE="$OUT_DIR/test_case_ids_to_generate.json"
  if [[ -f "$TEST_CASE_IDS" ]]; then
    cp "$TEST_CASE_IDS" "$IDS_FILE"
  else
    printf '%s\n' "$TEST_CASE_IDS" > "$IDS_FILE"
  fi
  RUN_IDS_ARG=(--run-ids)
fi

OVERWRITE_ARG=()
if [[ "${OVERWRITE:-0}" == "1" ]]; then
  OVERWRITE_ARG=(--allow-overwrite)
fi

echo "=== BFCL v4 run ==="
echo "  RUN_ID            : $RUN_ID"
echo "  Mode              : $BFCL_MODE  (is_fc_model via OpenAICompletionsHandler)"
echo "  BFCL model key    : $BFCL_MODEL_KEY"
echo "  Wire model id     : $RAW_MODEL"
echo "  Endpoint          : $OPENAI_BASE_URL"
echo "  Test categories   : $TEST_CATEGORY"
echo "  Threads           : $NUM_THREADS"
echo "  Temperature       : $TEMPERATURE"
echo "  Max gen tokens    : $MAX_GEN_TOKENS"
echo "  BFCL_PROJECT_ROOT : $OUT_DIR"
echo "  Bin               : $BFCL"
echo

# --- Phase 1 — generation ----------------------------------------------------
cd "$BFCL_DIR"

"$BFCL" generate \
  --model "$BFCL_MODEL_KEY" \
  --test-category "$TEST_CATEGORY" \
  --num-threads "$NUM_THREADS" \
  --temperature "$TEMPERATURE" \
  "${RUN_IDS_ARG[@]}" \
  "${OVERWRITE_ARG[@]}"

# --- Phase 2 — evaluation ----------------------------------------------------
"$BFCL" evaluate \
  --model "$BFCL_MODEL_KEY" \
  --test-category "$TEST_CATEGORY" \
  $PARTIAL_EVAL_FLAG

# --- Show the leaderboard row ------------------------------------------------
# `bfcl scores` hard-codes a column set that includes "Non-Live Exec Acc",
# which is absent from the CSV when exec categories weren't run (partial run).
# Print the CSV via Python so partial runs don't crash the wrapper.
SCORE_FILE="$OUT_DIR/score/data_overall.csv"
if [[ -f "$SCORE_FILE" ]]; then
  "$PYTHON" - "$SCORE_FILE" <<'PY'
import csv, sys, pathlib
path = pathlib.Path(sys.argv[1])
with path.open(newline="") as f:
    rows = list(csv.reader(f))
if not rows:
    print("(empty score file)")
    sys.exit(0)
header, data = rows[0], rows[1:]
# Show only the headline accuracy columns; on a partial run most will be "N/A",
# which is expected. This avoids the crash that `bfcl scores` hits when the
# "Non-Live Exec Acc" column is absent from a partial-run CSV.
wanted = ["Rank", "Model", "Overall Acc", "Non-Live AST Acc", "Live Acc",
          "Multi Turn Acc", "Relevance Detection", "Irrelevance Detection",
          "Organization", "License"]
idx = [header.index(w) for w in wanted if w in header]
print(" | ".join(f"{header[i]}: {data[0][i]}" for i in idx) if data else "(no rows)")
print(f"\nFull table: {path}")
PY
else
  echo "Score file not found: $SCORE_FILE"
fi

echo
echo "=== BFCL artifacts ==="
echo "  Results : $OUT_DIR/result/$(echo "$BFCL_MODEL_KEY" | tr '/' '_')/"
echo "  Scores  : $OUT_DIR/score/$(echo "$BFCL_MODEL_KEY" | tr '/' '_')/"
echo "  Overall : $OUT_DIR/score/data_overall.csv"
echo "  Non-live: $OUT_DIR/score/data_non_live.csv"
