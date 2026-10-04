# Running the 8-Benchmark Suite via the Docker Image

Operational playbook for launching a campaign through `quality-bench:latest`
instead of a local checkout -- the docker-run equivalent of
[`quality-benchmark-recipes.md`](quality-benchmark-recipes.md)'s "main
benchmark" recipe. Same subsets, same CCU, same config; only the launch
mechanism changes. For build instructions and the full env-var/volume
reference, see [`deployment/README.md`](../deployment/README.md) -- this doc
assumes the image is already built.

## Prerequisites

```bash
docker build -f deployment/Dockerfile -t quality-bench:latest .   # once, or after a patches/ change
mkdir -p jobs
```

Every command below assumes these exported (same contract as `.env` locally):

```bash
export API_KEY=sk-...
export OPENAI_BASE_URL=http://your-endpoint:8000/v1
export MODEL_NAME=z-ai/glm-5.2          # no openai/ prefix, same convention as .env
export RUN_ID=z-ai_glm-5.2              # pick once per campaign, reuse for every command below
export HF_TOKEN=hf_...                  # required: GPQA's dataset is gated on HF and fails without it;
                                         # MMLU-Pro/HLE read it too. Only skippable if you're exclusively
                                         # running LiveCodeBench/SciCode/BFCL/DeepSWE.
export HLE_JUDGE_BASE_URL=https://judge-endpoint/v1   # only if the endpoint above doesn't
export HLE_JUDGE_API_KEY=...                          # serve deepseek/deepseek-v4-pro + qwen/qwen3.7-plus
```

Add `-e HLE_JUDGE_BASE_URL -e HLE_JUDGE_API_KEY` to the `docker run` lines below
whenever you set them (general category / `run_hle.sh`).

`-v "$(pwd)/jobs:$(pwd)/jobs" -e JOBS_ROOT="$(pwd)/jobs"` is **required on every run** -- it's not just
where results land, it's where every benchmark's resume state lives (see
"Rerun / continue" below). Losing that mount means losing the ability to
resume.

The jobs dir must be mounted at the **same absolute path** inside the
container as on the host (not at `/app/jobs`). SWE-bench Pro's Phase-2 eval
and DeepSWE's `pier` bind-mount subdirectories of it into sibling containers
through the host docker socket, and the host daemon resolves those paths on
the host. With a container-only path like `/app/jobs/...`, the daemon quietly
creates an empty `/app/jobs/...` on the host and mounts that instead: every
SWE-bench Pro instance fails with `Entryscript failed ... return code: 127`
and every DeepSWE trial with `RewardFileNotFoundError`, so both score 0. For
agentic runs `entrypoint.sh` now checks this before starting and exits with an
error if the host can't see `JOBS_ROOT`. Inside the container, `/app/jobs` is
a symlink to `JOBS_ROOT`, so the other benchmarks write there too. In CI, the
runner's filesystem and the docker daemon behind the socket must be on the
same machine.

## Start: the full main-benchmark recipe (all 8, sequential by category)

Equivalent of `RUN_ID=<run-id> bash scripts/run_main_benchmark.sh` with no args:

```bash
docker run --rm -it \
  -e API_KEY -e OPENAI_BASE_URL -e MODEL_NAME -e RUN_ID -e HF_TOKEN \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -v "$(pwd)/jobs:$(pwd)/jobs" -e JOBS_ROOT="$(pwd)/jobs" \
  quality-bench:latest
```

Just some categories, in the order given:

```bash
docker run --rm -it \
  -e API_KEY -e OPENAI_BASE_URL -e MODEL_NAME -e RUN_ID -e HF_TOKEN \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -v "$(pwd)/jobs:$(pwd)/jobs" -e JOBS_ROOT="$(pwd)/jobs" \
  quality-bench:latest general coding
```

The docker socket mount is only strictly needed for `agentic` (BFCL doesn't
need it; SWE-bench Pro and DeepSWE do). Safe to always include it if you're
not sure which categories you'll run.

## Recommended: one category per pane, same RUN_ID

Same reasoning as `run_main_benchmark.sh`'s header comment: SWE-bench Pro and
DeepSWE render a `rich` Live UI that needs a real TTY per pane, and the
agentic category alone is Docker-heavy enough to want it visibly isolated.
Open three tmux panes/windows instead of backgrounding one container:

```bash
# pane 1 -- General (GPQA -> MMLU-Pro -> HLE)
docker run --rm -it -e API_KEY -e OPENAI_BASE_URL -e MODEL_NAME -e RUN_ID -e HF_TOKEN \
  -v "$(pwd)/jobs:$(pwd)/jobs" -e JOBS_ROOT="$(pwd)/jobs" \
  quality-bench:latest general

# pane 2 -- Coding (LiveCodeBench -> SciCode)
docker run --rm -it -e API_KEY -e OPENAI_BASE_URL -e MODEL_NAME -e RUN_ID -e HF_TOKEN \
  -v "$(pwd)/jobs:$(pwd)/jobs" -e JOBS_ROOT="$(pwd)/jobs" \
  quality-bench:latest coding

# pane 3 -- Agentic (BFCL -> SWE-bench Pro -> DeepSWE), needs the docker socket
docker run --rm -it -e API_KEY -e OPENAI_BASE_URL -e MODEL_NAME -e RUN_ID -e HF_TOKEN \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -v "$(pwd)/jobs:$(pwd)/jobs" -e JOBS_ROOT="$(pwd)/jobs" \
  quality-bench:latest agentic

# spare pane -- keep disk headroom for the duration of pane 3
# (RUN_ID is required -- prune_loop.sh reads jobs/$RUN_ID/swebench-pro/ to
# decide which per-instance images are safe to reclaim)
docker run --rm -it \
  -e RUN_ID \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -v "$(pwd)/jobs:$(pwd)/jobs" -e JOBS_ROOT="$(pwd)/jobs" \
  --entrypoint bash quality-bench:latest benchmarks/swebench_pro/prune_loop.sh
```

Note this is opt-in, not automatic: nothing in `entrypoint.sh` starts a prune
loop on its own for any category, including `agentic`/`swebench_pro` --
you launch it yourself as a second, sibling `docker run` exactly as above,
the same as running `bash benchmarks/swebench_pro/prune_loop.sh` in its own pane locally.

### DeepSWE resume

Re-running `benchmarks/deepswe/run.sh` with the same `RUN_ID`, task count and CCU
resumes the job. pier skips trials that already have a `result.json`, even ones
that died of infra errors, so the script first removes trials whose error type is
in `RETRY_ERROR_TYPES` (default `RuntimeError CancelledError`) and reruns them.
Model-side failures such as `NonZeroAgentExitCodeError` are kept. `RESUME=0`
disables this. Resume replays the job's `config.json`, so the endpoint and key
stored there are used and trials are written to the job's original path; use a new
`JOB_NAME` if `OPENAI_BASE_URL` changed.

### DeepSWE needs its own prune loop

DeepSWE leaves images behind too, and `prune_loop.sh` does not touch them (it
only knows SWE-bench Pro images). pier names every trial `<task>__<7 random
chars>`, so each run creates fresh `<trial>-main` / `-pier-egress-proxy` tags
that nothing ever removes -- 304 of them (159GB reclaimable) had piled up on the
test host.

`benchmarks/deepswe/run.sh` now cleans up after itself: right after its `pier
run`/`pier job resume` call returns (success or failure), it does one
`benchmarks/deepswe/prune_loop.sh --once` pass scoped to its own `JOBS_DIR`, when
every trial -- including whichever one finished last -- is guaranteed done. So
even a lone `docker run ... benchmarks/deepswe/run.sh` with no sidecar leaves no
leftover images. Run `benchmarks/deepswe/prune_loop.sh` in a spare pane anyway for
a long multi-trial job, to reclaim disk incrementally *during* the run instead
of only at the very end:

```bash
docker run --rm -it \
  -e RUN_ID \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -v "$(pwd)/jobs:$(pwd)/jobs" -e JOBS_ROOT="$(pwd)/jobs" \
  --entrypoint bash quality-bench:latest benchmarks/deepswe/prune_loop.sh
```

- It removes a trial's images only once that trial has a `result.json`, and only
  repositories that look like pier trial images of a task under
  `deep-swe/tasks`. `quality-bench`, `jefzda/*` and base images cannot match.
- One-off cleanup of leftovers from earlier runs: the same script with `--sweep`
  (add `DRY_RUN=1` to only list). It refuses to run while a trial is live.
  `--once` (needs `RUN_ID` or `JOBS_DIR`) does a single scoped pass instead of
  looping -- that's what `run_deepswe.sh` calls on its own.
- It never touches the docker build cache, which is shared with every other
  build on the host. Set `PRUNE_BUILD_CACHE=1` to also run `docker builder prune`
  when the docker data root is above `CACHE_PCT` (default 85).
- Check disk on the docker data root (`docker info --format '{{.DockerRootDir}}'`),
  which is often a different filesystem from `/`.

All three panes can run in parallel if the endpoint has capacity -- see the
CCU/cap table in `quality-benchmark-recipes.md`.

## Running a single benchmark directly

Bypasses `run_main_benchmark.sh` entirely; any `benchmarks/<name>/run.sh` works (or just the benchmark name), with
its own overrides passed as ordinary `-e` flags. The exact vetted flags per
benchmark (subset size, CCU, `MAX_GEN_TOKENS`) are encoded in
`scripts/run_main_benchmark.sh`'s `run_general`/`run_coding`/`run_agentic`
functions -- copy them from there, they're identical whether run locally or
in the container:

```bash
docker run --rm -it \
  -e API_KEY -e OPENAI_BASE_URL -e MODEL_NAME -e RUN_ID -e HF_TOKEN \
  -e NUM_CONCURRENT=8 -e REQUEST_TIMEOUT=3600 \
  -v "$(pwd)/jobs:$(pwd)/jobs" -e JOBS_ROOT="$(pwd)/jobs" \
  quality-bench:latest benchmarks/gpqa/run.sh
```

```bash
# SWE-bench Pro -- needs the docker socket
docker run --rm -it \
  -e API_KEY -e OPENAI_BASE_URL -e MODEL_NAME -e RUN_ID -e HF_TOKEN \
  -e WORKERS=4 -e EVAL_WORKERS=4 -e LIMIT=200 \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -v "$(pwd)/jobs:$(pwd)/jobs" -e JOBS_ROOT="$(pwd)/jobs" \
  quality-bench:latest benchmarks/swebench_pro/run.sh
```

## Smoke testing with a handful of samples

**Don't smoke-test through `run_main_benchmark.sh` (no trailing args, or
`general`/`coding`/`agentic`).** It's designed to pin the vetted subset
sizes/CCU so campaigns stay comparable (see its own header comment: "Do not
change subset sizes, CCU, or `MAX_GEN_TOKENS` here without a reason"), so most
of its `run_step` calls hardcode their own `LIMIT`/`TEST_CATEGORY`
(`env ... LIMIT=36 bash benchmarks/mmlu_pro/run.sh`, etc.) -- an external
`-e LIMIT=5` on `docker run` gets shadowed by that inner `env LIMIT=36` for
every benchmark except GPQA, which is the one call without a hardcoded
`LIMIT`. Passing `-e LIMIT=` to a full/category run will silently *not* do
what you expect.

For a real smoke test, invoke each `benchmarks/<name>/run.sh` directly (same pattern
as "Running a single benchmark directly" above) with a small sample count.
The var that controls sample count differs per benchmark:

| Benchmark | Var | Example |
|---|---|---|
| GPQA / MMLU-Pro / HLE | `LIMIT` | `LIMIT=4` |
| LiveCodeBench | `LIMIT` | `LIMIT=4` |
| SciCode | `LIMIT` (+ optionally `SPLIT=validation` to avoid burning test-split samples) | `LIMIT=2` |
| SWE-bench Pro | `LIMIT` (first N instances) | `LIMIT=4` |
| BFCL | no `LIMIT` -- its default `TEST_CATEGORY` is already the smoke-friendly AST-only subset; narrow further with `TEST_CASE_IDS` (specific test-case ids, see the script's own comment) if needed | `NUM_THREADS=1` |
| DeepSWE | `N_TASKS` (positional arg or env var) + `CCU` | `run_deepswe.sh 1 1` |

```bash
docker run --rm -it \
  -e API_KEY -e OPENAI_BASE_URL -e MODEL_NAME -e RUN_ID -e HF_TOKEN \
  -e LIMIT=4 -e NUM_CONCURRENT=1 \
  -v "$(pwd)/jobs:$(pwd)/jobs" -e JOBS_ROOT="$(pwd)/jobs" \
  quality-bench:latest benchmarks/gpqa/run.sh

docker run --rm -it \
  -e API_KEY -e OPENAI_BASE_URL -e MODEL_NAME -e RUN_ID -e HF_TOKEN \
  -e LIMIT=4 -e WORKERS=1 \
  -v /var/run/docker.sock:/var/run/docker.sock -v "$(pwd)/jobs:$(pwd)/jobs" -e JOBS_ROOT="$(pwd)/jobs" \
  quality-bench:latest benchmarks/swebench_pro/run.sh

docker run --rm -it \
  -e API_KEY -e OPENAI_BASE_URL -e MODEL_NAME -e RUN_ID -e HF_TOKEN \
  -v /var/run/docker.sock:/var/run/docker.sock -v "$(pwd)/jobs:$(pwd)/jobs" -e JOBS_ROOT="$(pwd)/jobs" \
  quality-bench:latest benchmarks/deepswe/run.sh 1 1
```

The repo already has a dedicated all-8, one-sample-count-per-benchmark smoke
driver, `scripts/run_all_smoke_sequential.sh` (`LIMIT=4`/`2` + `NUM_THREADS`/
`WORKERS`/`CCU=1`, with a retry/cooldown loop for rate-limited endpoints) --
this is what was used to smoke-test the image itself before it was committed.
It works the same way through the container:

```bash
docker run --rm -it \
  -e API_KEY -e OPENAI_BASE_URL -e MODEL_NAME -e RUN_ID -e HF_TOKEN \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -v "$(pwd)/jobs:$(pwd)/jobs" -e JOBS_ROOT="$(pwd)/jobs" -v "$(pwd)/logs:/app/logs" \
  quality-bench:latest scripts/run_all_smoke_sequential.sh
```

Two caveats specific to running it through the container (neither applies
when running it locally):

- It logs its own retry-loop status to `logs/$RUN_ID/`, separate from
  `jobs/$RUN_ID/` -- mount `-v $(pwd)/logs:/app/logs` too, or those logs
  vanish with the container on exit.
- `entrypoint.sh`'s `needs_docker()` check greps the **literal argv**
  for `agentic`/`swebench_pro`/`deepswe`/`run_swebench_pro.sh`/`run_deepswe`
  to decide whether to preflight `docker info` and auto-run
  `benchmarks/swebench_pro/prepare_data.sh`. Since the argv here is just
  `scripts/run_all_smoke_sequential.sh`, that check doesn't fire even though
  the script's own SWE-bench Pro/DeepSWE legs need the socket. Always pass
  `-v /var/run/docker.sock:/var/run/docker.sock` yourself when using this
  script, and make sure `SWE-agent/data/instances.yaml` +
  `SWE-bench_Pro-os/data/swebench_pro_raw_sample.jsonl` already exist (from a
  mounted `swebench-pro-data`/`swebench-pro-agent-data` volume, or run
  `benchmarks/swebench_pro/prepare_data.sh` yourself first) -- otherwise its
  SWE-bench Pro leg fails on missing data instead of generating it.

## Rerun / continue a run

**Works identically to running the scripts locally -- rerun with the same
`docker run` command, same `RUN_ID`, same jobs mount.** Every
benchmark's resume state lives entirely under `jobs/$RUN_ID/<benchmark>/`, on
the host, not inside the container, so a fresh container picks up exactly
where the last one left off:

| Benchmark(s) | Resume mechanism |
|---|---|
| GPQA / MMLU-Pro / HLE | SQLite `cache.db` under `jobs/$RUN_ID/<bench>/` -- prompts already answered are skipped, only failed/missing ones re-hit the endpoint |
| LiveCodeBench | `--continue_existing`, cached generations under `jobs/$RUN_ID/livecodebench/` |
| SciCode | `--continue-on-fail`, logs under `jobs/$RUN_ID/scicode/logs` |
| SWE-bench Pro | Phase 1 skips instances already in `jobs/$RUN_ID/swebench-pro/preds/preds.json`; Phase 2 skips instances with an existing `*_output.json` |
| DeepSWE (`run_deepswe_batches.sh`) | Batches with an existing `result.json` are skipped -- resumes from the first unfinished batch |

So "rerun" is just: run the exact same command again. No special flag needed
for the common case.

To force redoing something that already "succeeded" (rare -- only for
SWE-bench Pro, and only when you deliberately want to overwrite a prior
result rather than fill in gaps):

```bash
# Rerun specific failed instances by id (regex), leave everything else alone
docker run --rm -it \
  -e API_KEY -e OPENAI_BASE_URL -e MODEL_NAME -e RUN_ID -e HF_TOKEN \
  -e FILTER='django__django-1234|astropy__astropy-5678' \
  -v /var/run/docker.sock:/var/run/docker.sock -v "$(pwd)/jobs:$(pwd)/jobs" -e JOBS_ROOT="$(pwd)/jobs" \
  quality-bench:latest benchmarks/swebench_pro/run.sh

# Force re-running Phase 1 even for instances with an existing prediction
docker run ... -e REDO_EXISTING=1 ... quality-bench:latest benchmarks/swebench_pro/run.sh

# Force re-running Phase 2 eval even for instances with an existing output
docker run ... -e REDO_EVAL=1 ... quality-bench:latest benchmarks/swebench_pro/run.sh
```

Before rerunning anything, check whether the failure was infra (disk-full,
Docker network-pool exhaustion, endpoint dropped the connection -- rerun) or
a genuine model failure (bad patch, protocol violation, limits exceeded --
do **not** rerun, it counts) -- see memory `benchmark-failure-attribution`.

**SWE-bench Pro dataset files** (`SWE-agent/data/instances.yaml`,
`SWE-bench_Pro-os/data/swebench_pro_raw_sample.jsonl`) regenerate on every
fresh container unless you also mount:

```bash
-v swebench-pro-data:/app/SWE-bench_Pro-os/data \
-v swebench-pro-agent-data:/app/SWE-bench_Pro-os/SWE-agent/data
```

They're pinned to HF revision `7ab5114` (731 tasks, v1) through
`SWEBENCH_PRO_HF_REVISION`. Leave that pin alone: the current HF default (V2,
642 tasks) uses test names the eval parsers don't emit, which scores nearly
everything false. See `deployment/README.md`.

Without those two, rerun/continue still works correctly (instance-level
resume is entirely `preds.json`-driven), it just redoes that one prep step
needlessly on every container start.

## Monitoring a run in progress

`docker run -it` already shows the live `rich` UI in the foreground pane. For
a persisted transcript on top of that, or to check progress from another
terminal, exec into the running container -- don't pipe `docker run`'s
stdout through `tee` (degrades the Live UI, see memory
`swebench-pro-tty-piping`):

```bash
docker ps                                   # find the container id/name
docker exec -it <container> tmux capture-pane -p   # if the entrypoint runs inside tmux, else:
docker exec -it <container> bash -c "cd /app && bash scripts/progress.sh"
```

Or, since `jobs/` is on the host, just read it directly without touching the
container at all:

```bash
bash scripts/progress.sh          # from the host checkout, same jobs/ dir
RUN_ID=$RUN_ID bash benchmarks/swebench_pro/watch_run.sh   # SWE-bench Pro-specific liveness/disk watcher
```

## Viewing results

Same layout as running locally -- `jobs/` is a bind mount, so nothing is
container-specific:

```bash
jq . jobs/$RUN_ID/gpqa/result.json
jq . jobs/$RUN_ID/swebench-pro/eval/*_output.json
uv tool run --from datacurve-pier pier view jobs/$RUN_ID/deepswe-batches
```

Never trust the accumulated stdout/progress-bar number over these files --
see memory `swebench-pro-metric-pitfalls` / `bfcl-overall-acc-pitfall`.
