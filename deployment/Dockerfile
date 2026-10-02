# syntax=docker/dockerfile:1
# Centralized image for the 8-benchmark quality suite (see top-level
# README.md). Build once, run anywhere by supplying an OpenAI-compatible
# endpoint + api key + model name -- see deployment/README.md for the full
# usage contract.
#
# Layout mirrors the local repo exactly (BFCL/, LiveCodeBench/, SciCode/,
# SWE-bench_Pro-os/, deep-swe/, scripts/, tasks/ all under /app) so every
# scripts/run_*.sh works completely unmodified inside the container.
#
# Each patched benchmark is rebuilt from a fresh upstream clone at the exact
# commit our local changes are based on, with the corresponding patch under
# patches/ applied on top -- NOT copied from the local checkout. This keeps
# the image reproducible from tracked source (git commit + patch file)
# instead of whatever incidental local state happens to be on disk. The one
# exception is deep-swe/, which has no upstream remote (see its own git
# history) and SciCode's eval/data/test_data.h5, a ~1GB data blob with no
# programmatic source -- both are copied in from the build context (see
# .dockerignore).

ARG UV_VERSION=0.11
FROM ghcr.io/astral-sh/uv:${UV_VERSION} AS uv-bin

# --- base: OS deps + uv + all python versions the 8 benchmarks need --------
# Each benchmark keeps the python version it was actually built/vetted
# against locally (BFCL 3.10, LiveCodeBench/SWE-bench-Pro 3.11, SciCode/lm-eval
# 3.12) rather than forcing one version. uv manages these as standalone
# interpreters, so no per-version system python/apt juggling is needed.
FROM ubuntu:22.04 AS base
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
      git ca-certificates build-essential \
      docker.io docker-compose-v2 \
      tmux jq procps \
    && rm -rf /var/lib/apt/lists/*
# docker.io gives us the `docker` CLI binary used by mini-swe-agent's
# subprocess-based DockerEnvironment (both SWE-bench Pro and DeepSWE shell
# out to `docker ...`, they don't use the python SDK for container launch) --
# the daemon itself is never started here; /var/run/docker.sock must be
# bind-mounted from the host at `docker run` time.
# docker-compose-v2 installs `docker compose` as a CLI plugin -- DeepSWE's
# pier tool shells out to `docker compose ... --project-name ...` to bring up
# each task's environment; without this plugin the `docker` CLI doesn't
# recognize the `compose` subcommand at all, and every DeepSWE trial fails
# immediately with a RuntimeError before the agent ever runs.
# procps provides pgrep, used by scripts/watch_run.sh and prune_loop.sh.

COPY --from=uv-bin /uv /uvx /usr/local/bin/
ENV UV_LINK_MODE=copy
RUN uv python install 3.10 3.11 3.12

# --- bfcl: BFCL v4 (Python 3.10) --------------------------------------------
FROM base AS bfcl
WORKDIR /app
# Base commit + patch per patches/bfcl/*.patch (`From <hash>` line).
RUN git clone --filter=blob:none https://github.com/ShishirPatil/gorilla.git /tmp/gorilla \
    && cd /tmp/gorilla && git checkout 6ea5797 \
    && mkdir -p /app/BFCL && mv berkeley-function-call-leaderboard /app/BFCL/ \
    && rm -rf /tmp/gorilla
COPY patches/bfcl/ /tmp/patches-bfcl/
# The patch's diff paths are rooted at the gorilla monorepo checkout (the
# local repo this was extracted from had its .git at BFCL/, one level above
# berkeley-function-call-leaderboard/), so apply from /app/BFCL, not from
# inside the subdirectory.
RUN cd /app/BFCL \
    && git apply /tmp/patches-bfcl/*.patch \
    && rm -rf /tmp/patches-bfcl
WORKDIR /app/BFCL/berkeley-function-call-leaderboard
# torch (CUDA build) is pulled in transitively via sentence-transformers, a
# hard dep for BFCL's memory/rag categories we don't run in the main
# benchmark (TEST_CATEGORY=single_turn) -- kept as-is to reproduce exactly
# what's actually installed/vetted locally, not trimmed.
# Cache mount: persists uv's download/wheel cache across builds (a plain
# layer cache doesn't survive an interrupted/retried RUN, and this stage's
# CUDA download is multi-GB and slow).
RUN --mount=type=cache,target=/root/.cache/uv \
    uv venv .venv-bfcl --python 3.10 \
    && uv pip install --python .venv-bfcl/bin/python -e . \
    && uv pip install --python .venv-bfcl/bin/python soundfile==0.14.0
# soundfile: qwen_agent (imported unconditionally by model_config.py) needs it
# but doesn't declare it; the local venv had it installed by hand. Without it
# every BFCL run dies at import with "No module named 'soundfile'".

# --- lcb: LiveCodeBench (Python 3.11) ---------------------------------------
FROM base AS lcb
WORKDIR /app
# Base commit + patch per patches/livecodebench/*.patch.
RUN git clone --filter=blob:none https://github.com/LiveCodeBench/LiveCodeBench.git /app/LiveCodeBench \
    && cd /app/LiveCodeBench && git checkout 28fef95
COPY patches/livecodebench/ /tmp/patches-lcb/
RUN cd /app/LiveCodeBench && git apply /tmp/patches-lcb/*.patch && rm -rf /tmp/patches-lcb
WORKDIR /app/LiveCodeBench
# pyproject.toml declares torch>=2.3.0/vllm>=0.5.0.post1 as hard deps, but
# they're only used for local-model inference; the OpenAI-API codegeneration
# path scripts/run_livecodebench.sh actually uses (oai_runner.py) never
# imports them. The locally-vetted venv confirms this (no torch/vllm
# installed, works fine) -- so install with --no-deps + the actual runtime
# dependency set instead of a plain `-e .`, which would otherwise pull
# multi-GB CUDA wheels for nothing.
RUN --mount=type=cache,target=/root/.cache/uv \
    uv venv .venv-lcb --python 3.11 \
    && uv pip install --python .venv-lcb/bin/python -e . --no-deps \
    && uv pip install --python .venv-lcb/bin/python \
         openai mistralai==0.4.2 cohere anthropic==0.49.0 google-genai together \
         datasets==3.5.0 fsspec==2024.12.0 pebble annotated-types
# Pinned to the locally-vetted venv: anthropic>=1.0 dropped HUMAN_PROMPT/AI_PROMPT,
# which lcb_runner/prompts imports at module load (every LCB run dies at
# import), and datasets>=4.0 dropped the loading-script support the
# livecodebench/code_generation_lite dataset relies on.

# --- scicode: SciCode (Python 3.12) -----------------------------------------
FROM base AS scicode
WORKDIR /app
# Clean checkout, no local patch (confirmed during the earlier patch-extraction pass).
RUN git clone --filter=blob:none https://github.com/scicode-bench/SciCode.git /app/SciCode \
    && cd /app/SciCode && git checkout e3158ea
WORKDIR /app/SciCode
# `-e .` alone pulls in inspect-ai + litellm (SciCode's own direct deps);
# h5py bundles its own libhdf5 in the wheel, no apt package needed.
RUN --mount=type=cache,target=/root/.cache/uv \
    uv venv /app/.venv-scicode --python 3.12 \
    && uv pip install --python /app/.venv-scicode/bin/python -e . openai==3.3.1
# openai: SciCode doesn't pin it, and the resolver picks 2.x, but inspect_ai's
# OpenAI provider refuses to start below 3.1.0 (the local venv has 3.3.1).
# The venv lives at /app/.venv-scicode, not inside SciCode/: scripts/run_scicode.sh
# (and retry_/ci_run_scicode.sh) call $WORKSPACE_DIR/.venv-scicode/bin/inspect,
# matching the local layout.
# test_data.h5 has no programmatic source (SciCode's README: manual Google
# Drive download) -- copied from the build context, see .dockerignore.
COPY SciCode/eval/data/test_data.h5 /app/SciCode/eval/data/test_data.h5

# --- swebenchpro: SWE-bench Pro + submodules (Python 3.11) ------------------
FROM base AS swebenchpro
WORKDIR /app
RUN git clone --filter=blob:none https://github.com/scaleapi/SWE-bench_Pro-os.git /app/SWE-bench_Pro-os \
    && cd /app/SWE-bench_Pro-os && git checkout ca10a60
# Adds --revision to generate_sweagent_instances.py so the HF dataset can be
# pinned (see SWEBENCH_PRO_HF_REVISION in prepare-swebench-pro-data.sh).
COPY patches/swebench-pro/ /tmp/patches-swbp/
RUN cd /app/SWE-bench_Pro-os && git apply /tmp/patches-swbp/*.patch && rm -rf /tmp/patches-swbp

# SWE-agent submodule: unmodified, pinned exactly per .gitmodules. Only
# needed to satisfy requirements.txt imports + provide the on-disk path
# generate_sweagent_instances.py writes instances.yaml into -- the mini-swe-
# agent scaffold (not SWE-agent/SWE-Rex) is what actually drives the model at
# runtime (see swebench_pro.yaml: environment_class: docker), because SWE-
# Rex's glibc-based builder fails on the sweap images.
RUN cd /app/SWE-bench_Pro-os \
    && git clone --filter=blob:none https://github.com/scaleapi/SWE-agent.git SWE-agent \
    && cd SWE-agent && git checkout 402a7b8

# mini-swe-agent submodule: base commit + our local streaming patch (avoids
# idle-timeout disconnects mid-long-CoT) on top.
RUN cd /app/SWE-bench_Pro-os \
    && git clone --filter=blob:none https://github.com/scaleapi/mini-swe-agent mini-swe-agent \
    && cd mini-swe-agent && git checkout d74716a
COPY patches/swebench-pro-mini-swe-agent/ /tmp/patches-mswea/
RUN cd /app/SWE-bench_Pro-os/mini-swe-agent \
    && git apply /tmp/patches-mswea/*.patch \
    && rm -rf /tmp/patches-mswea

WORKDIR /app/SWE-bench_Pro-os
RUN --mount=type=cache,target=/root/.cache/uv \
    uv venv /app/.venv-swebenchpro --python 3.11 \
    && uv pip install --python /app/.venv-swebenchpro/bin/python -r requirements.txt \
    && uv pip install --python /app/.venv-swebenchpro/bin/python -e SWE-agent \
    && uv pip install --python /app/.venv-swebenchpro/bin/python -e mini-swe-agent
# NOTE: SWE-agent/data/instances.yaml and data/swebench_pro_raw_sample.jsonl
# are deliberately NOT generated here -- they're gitignored/regenerable and
# the latter needs HF_TOKEN, which we don't want baked into an image layer.
# deployment/prepare-swebench-pro-data.sh generates both lazily on first run
# (see entrypoint.sh); mount a volume over SWE-bench_Pro-os/data +
# SWE-agent/data to persist them across container runs.

# --- lmeval: GPQA / MMLU-Pro / HLE via lm-eval (Python 3.12) ----------------
FROM base AS lmeval
WORKDIR /app
RUN --mount=type=cache,target=/root/.cache/uv \
    uv venv .venv-lmeval --python 3.12 \
    && uv pip install --python .venv-lmeval/bin/python "lm-eval[api]==0.4.12" \
         pillow==12.3.0 immutabledict==4.3.1 langdetect==1.0.9
# Not pulled in by lm-eval[api] but present in the locally-vetted venv:
# pillow -- HLE's dataset has an image column, and decoding it fails without it;
# immutabledict + langdetect -- IFEval's instruction checkers.
# .venv-lighteval (present locally) is confirmed dead weight -- nothing in
# scripts/ or tasks/ references lighteval -- so it's intentionally not built.

# --- runtime: assemble the final image --------------------------------------
FROM base AS runtime
WORKDIR /app

COPY --from=bfcl        /app/BFCL              /app/BFCL
COPY --from=lcb         /app/LiveCodeBench     /app/LiveCodeBench
COPY --from=scicode     /app/SciCode            /app/SciCode
COPY --from=scicode     /app/.venv-scicode      /app/.venv-scicode
COPY --from=swebenchpro /app/SWE-bench_Pro-os  /app/SWE-bench_Pro-os
COPY --from=swebenchpro /app/.venv-swebenchpro /app/.venv-swebenchpro
COPY --from=lmeval      /app/.venv-lmeval       /app/.venv-lmeval

# Warm the uv cache with pier (DeepSWE driver) so `uv tool run --from
# datacurve-pier pier ...` in scripts/run_deepswe*.sh does not re-download ~140
# packages on every run. Kept before COPY scripts/ so script edits don't rebuild it.
RUN uv tool run --from datacurve-pier pier --help >/dev/null

# Vendored, no-upstream baseline (pinned to task-schema v1.1 -- see its own
# git history for the full rationale) -- copied wholesale, not cloned+patched.
COPY deep-swe/ /app/deep-swe/

# Orchestration layer.
COPY scripts/ /app/scripts/
COPY tasks/ /app/tasks/
COPY docs/ /app/docs/
COPY patches/ /app/patches/
COPY deepswe_tasks_*.txt /app/
COPY README.md .env.example /app/
COPY deployment/entrypoint.sh deployment/prepare-swebench-pro-data.sh /app/deployment/
RUN chmod +x /app/deployment/entrypoint.sh /app/deployment/prepare-swebench-pro-data.sh /app/scripts/*.sh

ENTRYPOINT ["/app/deployment/entrypoint.sh"]
# Default: the vetted main-benchmark recipe, all 3 categories sequentially --
# same default as `bash scripts/run_main_benchmark.sh` with no args.
CMD ["general", "coding", "agentic"]
