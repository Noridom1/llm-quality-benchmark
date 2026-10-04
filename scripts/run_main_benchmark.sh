#!/usr/bin/env bash
# "Main benchmark" -- the vetted 8-benchmark quality suite, fixed so results
# are comparable across different models (same subset/manifest, same
# MAX_GEN_TOKENS, same CCU per benchmark).
#
# This is the config that actually ran clean for RUN_ID=glm5.2-selfhost-extended
# (2026-09-09/10) and was reused verbatim for RUN_ID=glm5.3-w4afp8
# (2026-09-11/13) specifically so the two campaigns would be comparable. See
# docs/quality-benchmark-recipes.md ("Main benchmark (default going forward)")
# for the full rationale/measured wall-clock per benchmark, and
# jobs/glm5.2-selfhost-extended/README.md / jobs/glm5.3-w4afp8/README.md for
# the two results this config produced. Do not change subset sizes, CCU, or
# MAX_GEN_TOKENS here without a reason -- that's what breaks comparability.
#
# Usage:
#   bash scripts/run_main_benchmark.sh                    # all 3 categories, sequential
#   bash scripts/run_main_benchmark.sh general             # just GPQA -> MMLU-Pro -> HLE
#   bash scripts/run_main_benchmark.sh coding agentic       # just those two, in order given
#   RUN_ID=my-model bash scripts/run_main_benchmark.sh
#
# Categories run sequentially within this one invocation, in the given order.
# To run categories in PARALLEL (recommended once you've confirmed endpoint
# capacity -- see the CCU/cap table in quality-benchmark-recipes.md), open
# separate tmux panes/windows and launch one category per pane with the same
# RUN_ID, e.g.:
#   pane 1: RUN_ID=my-model bash scripts/run_main_benchmark.sh general
#   pane 2: RUN_ID=my-model bash scripts/run_main_benchmark.sh coding
#   pane 3: RUN_ID=my-model bash scripts/run_main_benchmark.sh agentic
# Do not merge that into one backgrounded script: SWE-bench Pro's and
# DeepSWE's progress UI (rich Live) need a real TTY per pane, and the agentic
# category alone is Docker-heavy enough (SWE-bench Pro + DeepSWE both spin up
# containers) that you want it visibly isolated.
#
# Logging: this script deliberately does NOT pipe its own stdout through
# `tee` -- SWE-bench Pro and DeepSWE (pier) render a rich Live progress UI
# that needs a real TTY, and piping degrades it to flat line-by-line logs
# (see memory swebench-pro-tty-piping). If you want a full session transcript
# on top of what's already on screen, run this script inside tmux and use
# `tmux pipe-pane -o -t <pane> 'cat >> jobs/<run-id>/main_benchmark.log'`
# instead. Regardless, the authoritative results always live under
# jobs/<RUN_ID>/<benchmark>/ (eval_results.json, result.json, score/*.json,
# etc) -- never trust an accumulated stdout/progress-bar number over those
# files (see memory swebench-pro-metric-pitfalls / bfcl-overall-acc-pitfall).
#
# Infra failures (Docker disk-full, network-pool exhaustion) should be
# rerun; model failures (bad patch, protocol violation, LimitsExceeded)
# should not be -- see memory benchmark-failure-attribution. For SWE-bench
# Pro specifically, run `benchmarks/swebench_pro/prune_loop.sh` in a spare tmux pane for the
# duration of the agentic category to avoid the disk-full Docker crashes that
# hit the glm5.3-w4afp8 run (90/200 instances) before glm5.2-selfhost-extended
# added prune-loop and saw 0.
set -uo pipefail

cd "$(dirname "$0")/.."
WORKSPACE_DIR="$(pwd)"

set -a; source .env; set +a
export PATH="$HOME/.local/bin:$PATH"
export OPENAI_API_KEY="$API_KEY"
export PYTHONUNBUFFERED=1

RAW_MODEL="${MODEL_NAME#openai/}"
RUN_ID="${RUN_ID:-$(echo "$RAW_MODEL" | tr -c '[:alnum:]._-' '_')}"
export RUN_ID

# Single override point for generation length across all 8 benchmarks: every
# benchmarks/<name>/run.sh script's own MAX_GEN_TOKS/MAX_TOKENS/MAX_GEN_TOKENS default falls
# back to this env var, so exporting it once here is enough (verified against
# both campaigns' actual output files, not just the launch env -- see memory
# glm5.3-w4afp8-full-results). Override only if you have a specific reason;
# it must match across models being compared.
export MAX_GEN_TOKENS="${MAX_GEN_TOKENS:-65536}"

declare -A RESULTS=()

run_step() {
  local name="$1"; shift
  echo
  echo "============================================================"
  echo "[$name] starting $(date -Is)"
  echo "============================================================"
  if "$@"; then
    RESULTS["$name"]="OK"
  else
    RESULTS["$name"]="FAIL(rc=$?)"
  fi
  echo "[$name] -> ${RESULTS[$name]} at $(date -Is)"
}

run_general() {
  # GPQA Diamond -- full 198/198, 5-shot CoT, CCU 8
  run_step gpqa env RUN_ID="$RUN_ID" NUM_CONCURRENT=8 REQUEST_TIMEOUT=3600 \
    bash benchmarks/gpqa/run.sh

  # MMLU-Pro -- 36 questions/subject x 14 subjects = 504/12,032, CCU 8
  run_step mmlu_pro env RUN_ID="$RUN_ID" NUM_CONCURRENT=8 REQUEST_TIMEOUT=3600 LIMIT=36 \
    bash benchmarks/mmlu_pro/run.sh

  # HLE -- 125/subtask x 2 = 250/2,158 text-only, CCU 6, generate + 3 judges
  run_step hle env RUN_ID="$RUN_ID" NUM_CONCURRENT=6 REQUEST_TIMEOUT=3600 LIMIT=125 \
    bash benchmarks/hle/run.sh
}

run_coding() {
  # LiveCodeBench -- codegeneration, first 200/1,055 (release_latest), pass@1 n=1 temp=0, MULTIPROCESS=8
  # NOTE contamination flag (see jobs/glm5.3-w4afp8/README.md): release_latest
  # is a fixed, long-public problem set (2023-2024). If the model under test
  # has a training cutoff meaningfully later than the models this config was
  # vetted on, its LCB score may be inflated by memorization rather than
  # capability. Override RELEASE_VERSION to something newer than the model's
  # cutoff before trusting a near-saturated score.
  run_step livecodebench env RUN_ID="$RUN_ID" LIMIT=200 MULTIPROCESS=8 \
    bash benchmarks/livecodebench/run.sh

  # SciCode -- split=test, without_background, 30/65, CCU 8, fixed shuffle seed
  run_step scicode env RUN_ID="$RUN_ID" LIMIT=30 MAX_CONNECTIONS=8 SAMPLE_SHUFFLE=42 \
    bash benchmarks/scicode/run.sh
}

run_agentic() {
  # BFCL v4 -- all 13/13 single-turn categories (7 non-live + 6 live) =
  # 3,641/4,706 test cases. "single_turn" is a real alias in
  # bfcl_eval/constants/category_mapping.py (NON_LIVE_CATEGORY + LIVE_CATEGORY,
  # 7+6=13) -- confirmed against the harness source, not just the launch env.
  # Deliberately excludes multi_turn/memory/web_search/format_sensitivity.
  run_step bfcl env RUN_ID="$RUN_ID" TEST_CATEGORY=single_turn \
    bash benchmarks/bfcl/run.sh

  # SWE-bench Pro -- first 200/731 instances, CCU 4 agent / 4 eval
  run_step swebench_pro env RUN_ID="$RUN_ID" WORKERS=4 EVAL_WORKERS=4 LIMIT=200 \
    bash benchmarks/swebench_pro/run.sh

  # DeepSWE -- full 64/113 random-subset (seed 0) tasks, single CCU-8 run.
  # (The two prior campaigns dove into this via 2-3 batches while probing for
  # a safe CCU; CCU 16 exhausts Docker's default network-address-pool (~31
  # networks, 2/trial) and fails ~1/3 of trials -- see memory
  # deepswe-ccu-docker-network-limit. CCU 8 ran clean both times, so run the
  # full 64 at CCU 8 from the start instead of repeating that discovery.)
  run_step deepswe env RUN_ID="$RUN_ID" \
    bash benchmarks/deepswe/run.sh 64 8
}

CATEGORIES=("$@")
if [[ ${#CATEGORIES[@]} -eq 0 ]]; then
  CATEGORIES=(general coding agentic)
fi

echo "############################################################"
echo "# Main benchmark run"
echo "#   RUN_ID      : $RUN_ID"
echo "#   Model       : $RAW_MODEL"
echo "#   MAX_GEN_TOKENS (all benchmarks): $MAX_GEN_TOKENS"
echo "#   Categories  : ${CATEGORIES[*]}"
echo "#   Started     : $(date -Is)"
echo "############################################################"

for cat in "${CATEGORIES[@]}"; do
  case "$cat" in
    general) run_general ;;
    coding) run_coding ;;
    agentic) run_agentic ;;
    *)
      echo "Unknown category: $cat (expected: general, coding, agentic)" >&2
      exit 1
      ;;
  esac
done

echo
echo "############################################################"
echo "# Main benchmark summary   RUN_ID=$RUN_ID"
echo "############################################################"
for name in gpqa mmlu_pro hle livecodebench scicode bfcl swebench_pro deepswe; do
  if [[ -n "${RESULTS[$name]:-}" ]]; then
    printf "  %-14s : %s\n" "$name" "${RESULTS[$name]}"
  fi
done
echo "# Artifacts : jobs/$RUN_ID/{gpqa,mmlu_pro,hle,livecodebench,scicode,bfcl,swebench-pro,deepswe}/"
echo "# Finished  : $(date -Is)"
echo "############################################################"

# Non-zero exit when any step failed, so CI (or a caller checking $?) sees a
# red run instead of having to parse the summary above.
for name in "${!RESULTS[@]}"; do
  if [[ "${RESULTS[$name]}" != OK ]]; then
    exit 1
  fi
done
