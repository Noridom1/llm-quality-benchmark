#!/usr/bin/env bash
set -euo pipefail

# Set up the upstream harnesses and virtualenvs for DIRECT runs (no Docker).
# Mirrors the per-benchmark stages in deployment/Dockerfile exactly -- same
# upstream repos, same pinned commits, same patch series, same venv layout --
# so a direct run and an in-image run see identical code. If you change a pin
# or a patch, change both places (and the table in README.md).
#
# Usage: scripts/setup_upstream.sh <target>...   (or: all)
# Targets: bfcl lcb scicode swebenchpro lmeval   (gpqa/mmlu_pro/hle/ifeval
# all share the lmeval venv; deepswe needs no setup -- deep-swe/ is vendored)
#
# Prereqs: git, uv (https://docs.astral.sh/uv/getting-started/installation/).
# The agentic benchmarks (swebenchpro, deepswe) additionally need a working
# `docker` CLI + daemon at run time (sibling containers), but not for setup.

cd "$(dirname "$0")/.."
ROOT="$(pwd)"

log() { printf '\n=== %s ===\n' "$*"; }

# Clone-or-skip: an existing checkout is left alone (delete it to redo).
clone() { # clone <url> <dir> <pin>
  local url="$1" dir="$2" pin="$3"
  if [[ -e "$dir" ]]; then
    log "$dir already exists -- skipping clone (delete it to redo)"
  else
    git clone --filter=blob:none "$url" "$dir"
    git -C "$dir" checkout "$pin"
  fi
}

apply_patches() { # apply_patches <dir> <patch-dir>
  local dir="$1" patches="$2"
  if (cd "$dir" && git apply --check --reverse "$ROOT/$patches"/*.patch 2>/dev/null); then
    log "$dir: patches already applied -- skipping"
    return 0
  fi
  log "Applying $patches/*.patch in $dir"
  (cd "$dir" && git apply "$ROOT/$patches"/*.patch)
}

setup_bfcl() {
  log "BFCL v4 (gorilla monorepo @ 6ea5797, Python 3.10)"
  if [[ ! -e BFCL/berkeley-function-call-leaderboard ]]; then
    tmp="$(mktemp -d)"
    git clone --filter=blob:none https://github.com/ShishirPatil/gorilla.git "$tmp/gorilla"
    git -C "$tmp/gorilla" checkout 6ea5797
    mkdir -p BFCL
    mv "$tmp/gorilla/berkeley-function-call-leaderboard" BFCL/
    rm -rf "$tmp"
  else
    log "BFCL/ already exists -- skipping clone"
  fi
  # Patch diff paths are rooted at the gorilla checkout (one level above
  # berkeley-function-call-leaderboard/), so apply from BFCL/.
  apply_patches BFCL benchmarks/bfcl/patches
  cd BFCL/berkeley-function-call-leaderboard
  uv venv .venv-bfcl --python 3.10
  # -e . pulls the CUDA torch wheel via sentence-transformers (multi-GB);
  # that is what the vetted local venv has, so keep it.
  uv pip install --python .venv-bfcl/bin/python -e .
  # qwen_agent imports soundfile without declaring it (see Dockerfile).
  uv pip install --python .venv-bfcl/bin/python soundfile==0.14.0
  cd "$ROOT"
}

setup_lcb() {
  log "LiveCodeBench @ 28fef95, Python 3.11"
  clone https://github.com/LiveCodeBench/LiveCodeBench.git LiveCodeBench 28fef95
  apply_patches LiveCodeBench benchmarks/livecodebench/patches
  cd LiveCodeBench
  uv venv .venv-lcb --python 3.11
  # --no-deps + explicit runtime set: a plain -e . pulls multi-GB torch/vllm
  # wheels the OpenAI-API path never imports (see Dockerfile for the pins).
  uv pip install --python .venv-lcb/bin/python -e . --no-deps
  uv pip install --python .venv-lcb/bin/python \
    openai mistralai==0.4.2 cohere anthropic==0.49.0 google-genai together \
    datasets==3.5.0 fsspec==2024.12.0 pebble annotated-types
  cd "$ROOT"
}

setup_scicode() {
  log "SciCode @ e3158ea, Python 3.12 (no patch)"
  clone https://github.com/scicode-bench/SciCode.git SciCode e3158ea
  if [[ ! -f SciCode/eval/data/test_data.h5 ]]; then
    echo "WARNING: SciCode/eval/data/test_data.h5 is missing. It has no"
    echo "programmatic source -- download it manually (see SciCode's README,"
    echo "Google Drive link) and place it at SciCode/eval/data/test_data.h5."
  fi
  uv venv .venv-scicode --python 3.12
  uv pip install --python .venv-scicode/bin/python -e ./SciCode openai==3.3.1
}

setup_swebenchpro() {
  log "SWE-bench Pro @ ca10a60 (+ SWE-agent @ 402a7b8, mini-swe-agent @ d74716a), Python 3.11"
  clone https://github.com/scaleapi/SWE-bench_Pro-os.git SWE-bench_Pro-os ca10a60
  apply_patches SWE-bench_Pro-os benchmarks/swebench_pro/patches/swe-bench-pro
  clone https://github.com/scaleapi/SWE-agent.git SWE-bench_Pro-os/SWE-agent 402a7b8
  clone https://github.com/scaleapi/mini-swe-agent.git SWE-bench_Pro-os/mini-swe-agent d74716a
  apply_patches SWE-bench_Pro-os/mini-swe-agent benchmarks/swebench_pro/patches/mini-swe-agent
  uv venv .venv-swebenchpro --python 3.11
  uv pip install --python .venv-swebenchpro/bin/python -r SWE-bench_Pro-os/requirements.txt
  uv pip install --python .venv-swebenchpro/bin/python -e SWE-bench_Pro-os/SWE-agent
  uv pip install --python .venv-swebenchpro/bin/python -e SWE-bench_Pro-os/mini-swe-agent
  # instances.yaml / raw_sample.jsonl are generated lazily on first run by
  # benchmarks/swebench_pro/prepare_data.sh (needs HF_TOKEN in .env).
}

setup_lmeval() {
  log "lm-eval venv for GPQA / MMLU-Pro / HLE / IFEval (Python 3.12, no upstream)"
  uv venv .venv-lmeval --python 3.12
  # pillow (HLE image column), immutabledict + langdetect (IFEval checkers)
  # are not pulled in by lm-eval[api] but the vetted venv has them.
  uv pip install --python .venv-lmeval/bin/python "lm-eval[api]==0.4.12" \
    pillow==12.3.0 immutabledict==4.3.1 langdetect==1.0.9
}

if [[ $# -eq 0 ]]; then
  echo "Usage: scripts/setup_upstream.sh <target>... | all" >&2
  echo "Targets: bfcl lcb scicode swebenchpro lmeval" >&2
  exit 1
fi

for t in "$@"; do
  case "$t" in
    bfcl)       setup_bfcl ;;
    lcb)        setup_lcb ;;
    scicode)    setup_scicode ;;
    swebenchpro) setup_swebenchpro ;;
    lmeval)     setup_lmeval ;;
    all)        setup_lmeval; setup_bfcl; setup_lcb; setup_scicode; setup_swebenchpro ;;
    *) echo "Unknown target: $t (bfcl|lcb|scicode|swebenchpro|lmeval|all)" >&2; exit 1 ;;
  esac
done

log "Done. Next: cp .env.example .env, fill it in, then e.g."
echo "  RUN_ID=my-model bash benchmarks/gpqa/run.sh"
