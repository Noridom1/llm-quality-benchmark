#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
WORKSPACE_DIR="$(pwd)"

# Knobs may be set three ways, in increasing priority: built-in default, .env,
# then the command line. `set -a; source .env` would clobber a command-line
# override (VAR=x ./script) with the .env value, so snapshot the command-line
# values first and restore them after sourcing.
_CLI_OVERRIDES=()
for _v in JUDGE_MODEL SRC_SUBDIR OUT_DIR CACHE_DB SUBTASKS CONCURRENCY \
          JUDGE_TIMEOUT JUDGE_MAX_TOKENS MAX_RESP_CHARS LIMIT; do
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

# --- What this does ----------------------------------------------------------
# Re-grades a finished HLE run with an LLM judge, the way upstream HLE grades it,
# instead of lm-eval's string `exact_match`. It reads the run's logged samples
# (so it needs no new answer generation -- the model's responses are already on
# disk) and only spends judge tokens.
#
# Judge verdicts are cached in sqlite keyed by (judge model, prompt), so a second
# run is free and the verdict parsing can be fixed without re-judging. Use
# OFFLINE=1 to re-score from the cache with no network at all.
#
#   RUN_ID=glm5.2-selfhost-extended ./scripts/judge_hle.sh
#   RUN_ID=... JUDGE_MODEL=qwen/qwen3.7-plus ./scripts/judge_hle.sh   # 2nd opinion
#
# The judge must NOT be the model under test: a model grading its own answers is
# the standard way to inflate a score. Default is an independent model on the
# same endpoint, and the script refuses to run if the judge matches the model
# whose samples it is grading (override with ALLOW_SELF_JUDGE=1 -- only for a
# deliberate bias measurement, see hle-judged/SELF-JUDGE.md).
#
# JUDGE_MODEL can be set in .env (applies to every run) or on the command line
# (wins over .env, for a one-off second opinion).

RUN_ID="${RUN_ID:?set RUN_ID (e.g. RUN_ID=glm5.2-selfhost-extended)}"

# Which artifact directory under jobs/<RUN_ID>/ holds the samples to grade.
# Default is the re-scored run (fixed extraction regexes, task version 2.0).
SRC_SUBDIR="${SRC_SUBDIR:-hle-rescored}"
SRC_DIR="$WORKSPACE_DIR/jobs/$RUN_ID/$SRC_SUBDIR"

JUDGE_MODEL="${JUDGE_MODEL:-deepseek/deepseek-v4-pro}"
OUT_DIR="${OUT_DIR:-$WORKSPACE_DIR/jobs/$RUN_ID/hle-judged}"
CACHE_DB="${CACHE_DB:-$OUT_DIR/judge_cache.db}"

# Subtasks to grade. Upstream judges both answer types; multipleChoice is a
# useful independent check on the letter-extraction regex.
SUBTASKS="${SUBTASKS:-hle_exact_match hle_multiple_choice}"

CONCURRENCY="${CONCURRENCY:-6}"
JUDGE_TIMEOUT="${JUDGE_TIMEOUT:-900}"
JUDGE_MAX_TOKENS="${JUDGE_MAX_TOKENS:-4096}"
# Responses longer than this are sent head+tail only (the 6 runaway samples in
# the extended run are 94k-190k chars of reasoning with no final answer).
MAX_RESP_CHARS="${MAX_RESP_CHARS:-24000}"
LIMIT="${LIMIT:-0}"

export OPENAI_API_KEY="$API_KEY"

# lm-eval writes samples under <src>/<model-with-slashes-escaped>/.
SAMPLES=()
for sub in $SUBTASKS; do
  # Newest samples file for this subtask, if present.
  latest="$(find "$SRC_DIR" -name "samples_${sub}_*.jsonl" -type f 2>/dev/null | sort | tail -1)"
  if [[ -n "$latest" ]]; then
    SAMPLES+=("$latest")
  else
    echo "  note: no samples_${sub}_*.jsonl under $SRC_DIR -- skipping" >&2
  fi
done

if [[ ${#SAMPLES[@]} -eq 0 ]]; then
  echo "ERROR: no HLE samples files found under $SRC_DIR" >&2
  echo "       (the run must have been made with --log_samples)" >&2
  exit 1
fi

# --- Self-judge guard --------------------------------------------------------
# lm-eval writes samples under <src>/<model id with "/" replaced by "__">/, so
# the directory name identifies the model that produced these answers -- which
# is what matters here, not whatever MODEL_NAME happens to be set to now.
TESTED_MODEL="$(basename "$(dirname "${SAMPLES[0]}")" | sed 's|__|/|')"
if [[ "$JUDGE_MODEL" == "$TESTED_MODEL" ]]; then
  if [[ "${ALLOW_SELF_JUDGE:-0}" == "1" ]]; then
    echo "  WARNING: self-judge -- $JUDGE_MODEL is grading its own answers." >&2
    echo "           Results are a bias measurement, not a score to report." >&2
  else
    echo "ERROR: judge model ($JUDGE_MODEL) is the model under test ($TESTED_MODEL)." >&2
    echo "       A model grading its own answers is not a defensible score." >&2
    echo "       Set JUDGE_MODEL to an independent model, e.g.:" >&2
    echo "         RUN_ID=$RUN_ID JUDGE_MODEL=deepseek/deepseek-v4-pro $0" >&2
    echo "       Or ALLOW_SELF_JUDGE=1 for a deliberate bias measurement." >&2
    exit 2
  fi
fi

# --- Judge endpoint -----------------------------------------------------------
# An independent judge usually isn't served by the endpoint under test, so
# HLE_JUDGE_BASE_URL/HLE_JUDGE_API_KEY (from .env) point it elsewhere. Both
# fall back to the main endpoint. A self-judge is the model under test by
# definition, so it always uses the main endpoint.
if [[ "$JUDGE_MODEL" == "$TESTED_MODEL" ]]; then
  JUDGE_BASE_URL="$OPENAI_BASE_URL"
  JUDGE_API_KEY="$API_KEY"
else
  JUDGE_BASE_URL="${HLE_JUDGE_BASE_URL:-$OPENAI_BASE_URL}"
  JUDGE_API_KEY="${HLE_JUDGE_API_KEY:-$API_KEY}"
fi
export JUDGE_BASE_URL JUDGE_API_KEY

mkdir -p "$OUT_DIR"

echo "=== HLE LLM-judge re-grade ==="
echo "  RUN_ID      : $RUN_ID"
echo "  Source      : $SRC_DIR"
echo "  Model tested: $TESTED_MODEL"
echo "  Judge model : $JUDGE_MODEL"
echo "  Judge URL   : $JUDGE_BASE_URL"
echo "  Output      : $OUT_DIR"
echo "  Verdict cache: $CACHE_DB"
for s in "${SAMPLES[@]}"; do echo "  Samples     : ${s#$WORKSPACE_DIR/}"; done
echo

OFFLINE_ARG=()
if [[ "${OFFLINE:-0}" == "1" ]]; then
  OFFLINE_ARG=(--offline)
  echo "  OFFLINE: scoring from cached verdicts only, no judge calls"
fi

LIMIT_ARG=()
if [[ "$LIMIT" != "0" ]]; then
  LIMIT_ARG=(--limit "$LIMIT")
fi

"$WORKSPACE_DIR/.venv-lmeval/bin/python" "$WORKSPACE_DIR/scripts/judge_hle.py" \
  --samples "${SAMPLES[@]}" \
  --out "$OUT_DIR" \
  --judge-model "$JUDGE_MODEL" \
  --cache "$CACHE_DB" \
  --concurrency "$CONCURRENCY" \
  --timeout "$JUDGE_TIMEOUT" \
  --max-tokens "$JUDGE_MAX_TOKENS" \
  --max-resp-chars "$MAX_RESP_CHARS" \
  "${LIMIT_ARG[@]}" \
  "${OFFLINE_ARG[@]}"
