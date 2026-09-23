# Scripts

Wrappers that drive each benchmark against the OpenAI-compatible endpoint
configured in `../.env` (`API_KEY`, `OPENAI_BASE_URL`, `MODEL_NAME`).
All scripts `cd` to the repo root and source `.env` themselves.

| Script | Benchmark | Sandbox |
|---|---|---|
| `run_gpqa.sh` | GPQA-Diamond | None |
| `run_mmlu_pro.sh` | MMLU-Pro | None |
| `run_hle.sh` | HLE | None |
| `run_scicode.sh` | SciCode | Sandboxed Python |
| `run_livecodebench.sh` | LiveCodeBench | Sandboxed tests |
| `run_bfcl.sh` | BFCL v4 | None (AST) |
| `run_swebench_pro.sh` | SWE-bench Pro | Docker per instance |
| `run_deepswe.sh` | DeepSWE | Docker per task |
| `run_deepswe_batches.sh` | DeepSWE (full, batched) | Docker per task |
| `run_deepswe_tasks.sh` | DeepSWE, explicit task list | Docker per task |
| `retry_scicode.sh` | SciCode retry helper | Sandboxed Python |
| `run_ifeval.sh` | IFEval (not part of the core 8) | None |

## Other orchestration scripts

| Script | Purpose |
|---|---|
| `run_main_benchmark.sh` | The vetted "main benchmark" recipe (fixed subset sizes/CCU) -- see its own header comment and `docs/quality-benchmark-recipes.md`. |
| `run_general_balanced.sh` | Alternate "Balanced tier" recipe for GPQA/MMLU-Pro/HLE (smaller counts, CCU 2) instead of the main config. |
| `run_all_smoke_sequential.sh` | Sequential smoke test across all 8 benchmarks, one at a time, with retry/cooldown for rate-limited endpoints. |
| `run_deepswe_tasks.sh` | Resume/extend a DeepSWE run against an explicit task-list file (`deepswe_tasks_*.txt`) instead of a random N-task sample -- see its header comment for why (pier can't extend an existing job's task count). |
| `watch_run.sh` | Live monitoring/alert loop for a running SWE-bench Pro campaign (patch-count, disk space, prune-loop liveness). Usage: `RUN_ID=<id> bash scripts/watch_run.sh`. |
| `progress.sh` | Quick one-shot progress check across `jobs/<RUN_ID>/`. |
| `prune_loop.sh` | Continuous Docker image/container pruning, run alongside SWE-bench Pro to avoid disk-full crashes. |
| `prune_done_images.py` / `prune_failed_preds.py` | One-off cleanup helpers for SWE-bench Pro Docker images / failed prediction retries. |
| `judge_hle.py` / `judge_hle.sh` / `rescore_hle.sh` / `compare_judges.py` | HLE's 3-judge scoring pipeline and judge-comparison tooling. |

## DeepSWE

Two scripts to run [DeepSWE](https://deepswe.datacurve.ai/) (113 tasks across
TypeScript/Go/Python/JS/Rust) through [Pier](https://github.com/datacurve-ai/pier)
driving `mini-swe-agent` with litellm against the endpoint. Tasks live under
`deep-swe/tasks/`; each runs in its own Docker container, so `docker info` must
work before launching.

The scripts share the repo convention used by `run_swebench_pro.sh` /
`run_scicode.sh`: `MODEL_NAME` in `.env` is stored **without** the `openai/`
provider prefix (lm-eval style), and each script re-adds it for litellm:

```bash
RAW_MODEL="${MODEL_NAME#openai/}"   # z-ai/glm-5.2
--model "openai/${RAW_MODEL}"        # openai/z-ai/glm-5.2
```

Artifacts land under `jobs/<RUN_ID>/deepswe-*/` (matching the `jobs/<RUN_ID>/<benchmark>/`
layout used by the other benchmarks), where `RUN_ID` defaults to a slug of the
model name (e.g. `z-ai_glm-5.2`).

### run_deepswe.sh

Sampled subset for smoke / quick runs.

```bash
bash scripts/run_deepswe.sh [N_TASKS] [CCU]
```

- `N_TASKS`: number of tasks to sample (seed 0). Default 6.
- `CCU`: tasks to run in parallel. Defaults to `N_TASKS`.

Examples:

```bash
bash scripts/run_deepswe.sh            # 6 tasks, CCU 6
bash scripts/run_deepswe.sh 12         # 12 tasks, CCU 12
bash scripts/run_deepswe.sh 20 8       # 20 tasks, CCU 8
```

Results: `jobs/<RUN_ID>/deepswe-ccu<CCU>/`. Override `JOBS_DIR` or `JOB_NAME`
via env to customize.

### run_deepswe_batches.sh

Full 113-task corpus split into fixed batches, run sequentially. Batches with
an existing `result.json` are skipped, so re-running resumes from the first
unfinished batch.

```bash
CCU=6 BATCH_SIZE=20 bash scripts/run_deepswe_batches.sh
```

Env vars:

| Variable | Default | Description |
|---|---|---|
| `BATCH_SIZE` | `20` | Tasks per batch |
| `CCU` | `6` | Parallel tasks within a batch |
| `MAX_TASKS` | `113` | Total tasks to take (after filtering `ugc-*`) |
| `JOBS_DIR` | `jobs/<RUN_ID>/deepswe-batches` | Where results are written |
| `BATCH_DIR` | `task_batches` | Where per-batch task lists are written |
| `PRUNE_DOCKER_AFTER_BATCH` | `0` | `1` = prune stopped containers + unused images after each batch |
| `DOCKER_IMAGE_PRUNE_UNTIL` | `2h` | Min image age for prune when cleanup is on |
| `RUN_ID` | model slug | Campaign id; results land in `jobs/<RUN_ID>/deepswe-batches/` |

Task list excludes `ugc-*` tasks and is capped at `MAX_TASKS`; the script
errors if the count doesn't match.

Docker cleanup only removes stopped containers and unused images older than
`DOCKER_IMAGE_PRUNE_UNTIL`; build cache is kept so later batches reuse layers.

```bash
PRUNE_DOCKER_AFTER_BATCH=1 DOCKER_IMAGE_PRUNE_UNTIL=2h CCU=4 BATCH_SIZE=20 \
  bash scripts/run_deepswe_batches.sh
```

Smoke the batch flow (5 tasks, batches of 2, CCU 2):

```bash
MAX_TASKS=5 BATCH_SIZE=2 CCU=2 JOBS_DIR=jobs/<RUN_ID>/deepswe-batch-smoke \
  bash scripts/run_deepswe_batches.sh
```

## Viewing results

```bash
uv tool run --from datacurve-pier pier view <JOBS_DIR>
jq . <JOBS_DIR>/<job-name>/result.json
```
