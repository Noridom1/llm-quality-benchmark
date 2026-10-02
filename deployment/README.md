# Deployment

Centralizes the 8-benchmark quality suite into one Docker image. Build once;
any machine can then run any benchmark by supplying an OpenAI-compatible
endpoint + api key + model name, without installing any per-benchmark venvs.

This doc covers build + the env-var/volume contract. For the operational
playbook -- launching the vetted main-benchmark recipe, rerunning/continuing
a campaign, monitoring, viewing results -- see
[`docs/running-via-docker.md`](../docs/running-via-docker.md).

## Build

```bash
cd /home/stackops/benchmark
docker build -f deployment/Dockerfile -t quality-bench:latest .
```

This clones BFCL, LiveCodeBench, SciCode, and SWE-bench Pro (+ its `SWE-agent`
and `mini-swe-agent` submodules) fresh from upstream at build time and applies
our local patches from `patches/` on top -- it does **not** copy the local
checkouts (see `.dockerignore` / `deployment/Dockerfile` comments). Needs
network access during build. `deep-swe/` (no upstream remote) and SciCode's
`eval/data/test_data.h5` (~1GB, no programmatic source) are copied in from the
local checkout instead.

Expect a large image (combined per-benchmark venvs are ~8GB locally; BFCL
alone pulls a CUDA torch build transitively via `sentence-transformers`) and a
build that takes a while the first time. Each benchmark builds in its own
Docker stage, so a change to one benchmark's patch only invalidates that
stage's cache on rebuild.

## Run

```bash
docker run --rm -it \
  -e API_KEY=sk-... \
  -e OPENAI_BASE_URL=http://your-endpoint:8000/v1 \
  -e MODEL_NAME=z-ai/glm-5.2 \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -v "$(pwd)/jobs:$(pwd)/jobs" -e JOBS_ROOT="$(pwd)/jobs" \
  quality-bench:latest
```

With no trailing args this runs the full main-benchmark recipe (general +
coding + agentic, sequentially) -- the same default as
`bash scripts/run_main_benchmark.sh` with no args. Results land in
`jobs/<RUN_ID>/<benchmark>/` on the host via the mounted volume, exactly like
running the scripts locally.

### Choosing what to run

```bash
# Just one or two categories, in the order given (general/coding/agentic):
docker run ... quality-bench:latest general coding

# A single benchmark directly, bypassing run_main_benchmark.sh entirely --
# any script under scripts/ works, with its own env vars passed via -e:
docker run --rm -it \
  -e API_KEY=... -e OPENAI_BASE_URL=... -e MODEL_NAME=... \
  -e LIMIT=20 -e NUM_CONCURRENT=4 \
  quality-bench:latest scripts/run_gpqa.sh
```

### Env vars

| Variable | Required | Notes |
|---|---|---|
| `API_KEY` | yes | |
| `OPENAI_BASE_URL` | yes | Must point at the `/v1`-style base, not a specific route. |
| `MODEL_NAME` | yes | Without the `openai/` prefix (lm-eval convention) -- scripts add it back where needed. |
| `HF_TOKEN` | yes, for GPQA / MMLU-Pro / HLE / SWE-bench Pro | GPQA's dataset (`Idavidrein/gpqa`) is gated on Hugging Face and fails outright without it; MMLU-Pro/HLE also read it (higher rate limits / avoids "unauthenticated requests" throttling). For SWE-bench Pro it's needed to export the `ScaleAI/SWE-bench_Pro` dataset on first agentic run (see below). In short: set it unless you're only running LiveCodeBench/SciCode/BFCL/DeepSWE. |
| `HLE_MAIN_JUDGE` / `HLE_SECOND_JUDGE` / `HLE_SELF_JUDGE` | for HLE | Same as local `.env` -- see top-level `README.md`. Only forwarded when passed; leave unset to get the defaults. |
| `HLE_JUDGE_BASE_URL` / `HLE_JUDGE_API_KEY` | for HLE, when the endpoint under test doesn't serve the judge models | Where the independent judges are called. Default to `OPENAI_BASE_URL` / `API_KEY`. Without a reachable judge, HLE generation still completes but the run exits 1 with no score. |
| `RUN_ID`, `LIMIT`, `NUM_CONCURRENT`, `WORKERS`, `CCU`, etc. | no | Same per-benchmark overrides documented in `scripts/README.md` / `scripts/run_main_benchmark.sh`, passed through as ordinary `-e` flags. |

Any other env var a specific `scripts/run_*.sh` reads works the same way --
the entrypoint doesn't need to know about it, since `docker run -e` already
injects it into the container's environment before the script runs.

### Docker socket (required for `agentic` / SWE-bench Pro / DeepSWE)

SWE-bench Pro and DeepSWE launch per-instance/per-task Docker containers
themselves via the `docker` CLI (mini-swe-agent's `DockerEnvironment` shells
out to it, it doesn't use the python SDK for container launch). The image
can't run Docker *inside* itself usefully, so it needs the **host's** socket:

```bash
-v /var/run/docker.sock:/var/run/docker.sock
```

The containers it launches are then siblings on the host, not nested. This
also means the *host* needs disk headroom for SWE-bench Pro's per-instance
images (~1-3GB each) -- run a prune loop on the host, or pass
`-e ...` to invoke `scripts/prune_loop.sh` in a sibling container pointed at
the same socket. DeepSWE leaves its own per-trial images behind and needs
`scripts/prune_deepswe_loop.sh` instead (see `docs/running-via-docker.md`).
DeepSWE's CCU is capped at 8 by the host's default Docker
network-address-pool (~31 networks, 2/trial); `run_main_benchmark.sh` already
bakes this in.

### TTY

SWE-bench Pro and DeepSWE render a `rich` Live progress UI that needs a real
TTY -- pass `-it`. Without it the UI degrades to flat line-by-line logs
(functionally fine, just less readable). For a full transcript on top of what
scripts print, use `docker exec` + `tmux pipe-pane` inside the container
rather than piping `docker run`'s stdout through `tee` (same caveat as
running locally -- see `scripts/run_main_benchmark.sh`'s header comment).

### SWE-bench Pro dataset (first run only)

`SWE-agent/data/instances.yaml` and `SWE-bench_Pro-os/data/swebench_pro_raw_sample.jsonl`
aren't baked into the image (the former is a generated manifest, the latter
requires `HF_TOKEN` to export from Hugging Face -- baking a secret into an
image layer would be a mistake). `deployment/entrypoint.sh` generates both
automatically before an `agentic` or `swebench_pro` run if they're missing.

Both are pinned to HF revision `7ab5114` (the 731-task v1 dataset every
baseline was scored against) via `SWEBENCH_PRO_HF_REVISION`. Don't unpin it:
upstream's 2026-09-22 V2 commit (642 tasks) renamed the tests, and the repo's
`run_scripts/*/parser.py` still emit the old names, so nearly every instance
scores false even when its tests pass. Each file carries a `.hf-revision`
stamp, and a file from another revision on a persisted volume is regenerated.

To avoid regenerating them on every container run, mount a persistent volume:

```bash
-v swebench-pro-data:/app/SWE-bench_Pro-os/data \
-v swebench-pro-agent-data:/app/SWE-bench_Pro-os/SWE-agent/data
```

## What's intentionally different from a naive `pip install -e .` per repo

- **LiveCodeBench**: installed with `--no-deps` + an explicit runtime
  dependency list, dropping `torch`/`vllm` (declared in `pyproject.toml` but
  only used for local-model inference, never imported by the OpenAI-API path
  `scripts/run_livecodebench.sh` uses -- confirmed against the locally-vetted
  venv, which doesn't have them installed either).
- **BFCL**: kept as a plain `-e .`, including the transitive CUDA `torch`
  pull via `sentence-transformers` -- reproduces exactly what's vetted
  locally rather than trimming it, even though `TEST_CATEGORY=single_turn`
  (the main-benchmark config) doesn't exercise the memory/rag categories that
  need it.
- **lm-eval** (GPQA/MMLU-Pro/HLE): only `.venv-lmeval` is built.
  `.venv-lighteval`, present locally, is confirmed unused by anything in
  `scripts/`/`tasks/` and intentionally left out.
- **DeepSWE**: no venv at all -- it runs entirely via `uv tool run --from
  datacurve-pier pier run ...` (ephemeral, uv-cached) plus the
  `tasks/deepswe-pier-streaming/` sitecustomize patch, exactly as it does
  locally.
