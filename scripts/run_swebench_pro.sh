#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
WORKSPACE_DIR="$(pwd)"

set -a
source .env
set +a

# mini-swe-agent uses litellm, which reads OPENAI_API_KEY + OPENAI_API_BASE.
export OPENAI_API_KEY="$API_KEY"
export OPENAI_API_BASE="$OPENAI_BASE_URL"
# LitellmModel picks up MSWEA_MODEL_API_KEY and injects it as api_key in
# model_kwargs (see minisweagent.models.get_model).
export MSWEA_MODEL_API_KEY="$API_KEY"
# Suppress the global-cost-limit banner; we manage limits via step_limit/cost_limit.
export MSWEA_SILENT_STARTUP=1

# Use the workspace venv for mini-swe-agent + swe_bench_pro_eval.
PYTHON="$WORKSPACE_DIR/.venv-swebenchpro/bin/python"

# Strip the leading "openai/" prefix that our .env stores for lm-eval.
RAW_MODEL="${MODEL_NAME#openai/}"

# --- Run identity ------------------------------------------------------------
# RUN_ID identifies a full benchmark campaign (e.g. "gn_glm5.2").
# All benchmark artifacts land under jobs/<RUN_ID>/swebench-pro/.
# Re-running with the same RUN_ID resumes Phase 1 (mini-swe-agent skips
# instances already present in preds.json) and Phase 2 (eval skips instances
# with an existing <prefix>_output.json unless --redo is set).
RUN_ID="${RUN_ID:-$(echo "$RAW_MODEL" | tr -c '[:alnum:]._-' '_')}"

# --- Paths -------------------------------------------------------------------
SWEBENCH_DIR="$WORKSPACE_DIR/SWE-bench_Pro-os"
INSTANCES_YAML="$SWEBENCH_DIR/SWE-agent/data/instances.yaml"
RAW_SAMPLE="$SWEBENCH_DIR/data/swebench_pro_raw_sample.jsonl"
CONFIG="$WORKSPACE_DIR/tasks/swebench-pro/swebench_pro.yaml"

# JOBS_ROOT must be the same absolute path the host docker daemon sees:
# nested containers bind-mount subdirs of it (see docs/running-via-docker.md).
JOBS_ROOT="${JOBS_ROOT:-$WORKSPACE_DIR/jobs}"
OUT_DIR="$JOBS_ROOT/$RUN_ID/swebench-pro"
PRED_DIR="$OUT_DIR/preds"
PATCHES_JSON="$OUT_DIR/patches.json"
EVAL_DIR="$OUT_DIR/eval"

mkdir -p "$PRED_DIR" "$EVAL_DIR"

# --- Defaults (overridable via env) -----------------------------------------
# LIMIT: first N instances (smoke test). Empty = full 731-instance run.
LIMIT="${LIMIT:-}"
# Number of parallel Phase-1 agent workers (each spawns a docker container).
WORKERS="${WORKERS:-4}"
# Phase-2 eval parallelism (docker containers running tests).
EVAL_WORKERS="${EVAL_WORKERS:-4}"
# Restart instances that already have a prediction in preds.json.
REDO_EXISTING="${REDO_EXISTING:-0}"
# Redo Phase-2 eval even if <prefix>_output.json already exists.
REDO_EVAL="${REDO_EVAL:-0}"
# Docker Hub username hosting the per-instance sweap images (public, shared).
DOCKERHUB_USERNAME="${DOCKERHUB_USERNAME:-jefzda}"
# Cost/step limits per Phase-1 instance (defaults match the shipped config).
COST_LIMIT="${COST_LIMIT:-3.0}"
STEP_LIMIT="${STEP_LIMIT:-250}"
MAX_GEN_TOKENS="${MAX_GEN_TOKENS:-65536}"
# Seconds allowed for `docker run` including the image pull (upstream default
# is 120s, too short for the multi-GB sweap images under parallel pulls).
PULL_TIMEOUT="${PULL_TIMEOUT:-1800}"

# --- Build CLI args ---------------------------------------------------------
SLICE_ARG=()
if [[ -n "$LIMIT" ]]; then
  SLICE_ARG=(--slice "0:${LIMIT}")
fi

# FILTER: regex on instance_id, for rerunning a specific subset (e.g. infra
# failures) without re-touching instances that already have a valid result.
FILTER_ARG=()
if [[ -n "${FILTER:-}" ]]; then
  FILTER_ARG=(--filter "$FILTER")
fi

REDO_ARG=()
if [[ "$REDO_EXISTING" == "1" ]]; then
  REDO_ARG=(--redo-existing)
fi

REDO_EVAL_ARG=()
if [[ "$REDO_EVAL" == "1" ]]; then
  REDO_EVAL_ARG=(--redo)
fi

echo "=== SWE-bench Pro run ==="
echo "  RUN_ID            : $RUN_ID"
echo "  Model             : $RAW_MODEL"
echo "  Phase 1 (agent)   : mini-swe-agent (litellm -> $OPENAI_API_BASE)"
echo "  Phase 2 (eval)    : swe_bench_pro_eval.py --use_local_docker"
echo "  Instances yaml    : $INSTANCES_YAML"
echo "  Raw sample        : $RAW_SAMPLE"
echo "  Output dir        : $OUT_DIR"
echo "  Workers (agent)   : $WORKERS"
echo "  Workers (eval)    : $EVAL_WORKERS"
echo "  Cost/step limit   : \$${COST_LIMIT} / ${STEP_LIMIT} steps per instance"
echo "  Max gen tokens    : $MAX_GEN_TOKENS per agent turn"
echo "  Docker pull timeout: ${PULL_TIMEOUT}s"
if [[ -n "$LIMIT" ]]; then
  echo "  Limit             : first $LIMIT instances"
fi
echo

# Override step_limit/cost_limit in a temp config so we don't mutate the
# checked-in config file.
RUN_CONFIG="$OUT_DIR/run_config.yaml"
sed -e "s/step_limit: [0-9]*/step_limit: ${STEP_LIMIT}/" \
    -e "s/cost_limit: [0-9.]*$/cost_limit: ${COST_LIMIT}/" \
    -e "s/max_tokens: [0-9]*/max_tokens: ${MAX_GEN_TOKENS}/" \
    -e "s/pull_timeout: [0-9]*/pull_timeout: ${PULL_TIMEOUT}/" \
    "$CONFIG" > "$RUN_CONFIG"

# --- Phase 1: generate patches (mini-swe-agent drives the LLM) --------------
echo "--- Phase 1: agent patch generation ---"
"$PYTHON" "$WORKSPACE_DIR/tasks/swebench-pro/run_swebench_pro.py" \
  --instances-path "$INSTANCES_YAML" \
  --output "$PRED_DIR" \
  --config "$RUN_CONFIG" \
  --model "openai/${RAW_MODEL}" \
  --workers "$WORKERS" \
  "${SLICE_ARG[@]}" \
  "${FILTER_ARG[@]}" \
  "${REDO_ARG[@]}"

# --- Gather patches into the JSON shape swe_bench_pro_eval.py expects -------
echo "--- Gathering patches ---"
# mini-swe-agent writes a single preds.json object keyed by instance_id with
# {model_name_or_path, instance_id, model_patch}. Convert to the list shape.
"$PYTHON" - "$PRED_DIR/preds.json" "$PATCHES_JSON" <<'PY'
import json, sys
src, dst = sys.argv[1], sys.argv[2]
data = json.load(open(src))
patches = [
    {"instance_id": v["instance_id"], "patch": v.get("model_patch") or "", "prefix": "agent"}
    for v in data.values()
]
json.dump(patches, open(dst, "w"), indent=2)
print(f"Wrote {len(patches)} patches to {dst}")
PY

# --- Phase 2: evaluate patches (apply + run tests in pristine containers) --
echo "--- Phase 2: patch evaluation ---"
cd "$SWEBENCH_DIR"
"$PYTHON" swe_bench_pro_eval.py \
  --raw_sample_path "$RAW_SAMPLE" \
  --patch_path "$PATCHES_JSON" \
  --output_dir "$EVAL_DIR" \
  --scripts_dir run_scripts \
  --num_workers "$EVAL_WORKERS" \
  --dockerhub_username "$DOCKERHUB_USERNAME" \
  --use_local_docker \
  "${REDO_EVAL_ARG[@]}"

echo
echo "=== SWE-bench Pro complete ==="
echo "  Predictions : $PRED_DIR/preds.json"
echo "  Patches     : $PATCHES_JSON"
echo "  Eval results: $EVAL_DIR/eval_results.json"
echo
"$PYTHON" - <<PY
import json
r = json.load(open("$EVAL_DIR/eval_results.json"))
n = len(r)
p = sum(1 for v in r.values() if v)
print(f"Pass@1: {p}/{n} ({100*p/n:.1f}%)" if n else "No results")
PY
