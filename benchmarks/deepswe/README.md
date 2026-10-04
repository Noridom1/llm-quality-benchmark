# DeepSWE

Run the [DeepSWE](https://deepswe.datacurve.ai/) agent benchmark (113 long-horizon SE tasks across TypeScript/Go/Python/JS/Rust) via [Pier](https://github.com/datacurve-ai/pier) driving `mini-swe-agent`. Each task runs in an isolated Docker container; Pier then applies the agent's committed patch in a pristine verifier container and reports a binary reward + test pass fractions.

## Architecture

- **Agent**: `mini-swe-agent` (model-agnostic, bash-only) driven by Pier, litellm as the model class so calls go to `/v1/chat/completions` (the endpoint rejects `/v1/responses`). `--agent-kwarg model_class=litellm` is required.
- **Verifier**: per-task held-out tests run in a separate container against the agent's extracted patch. Produces `verifier/reward.json`, `ctrf.json`, `test-stdout.txt`, `run.log`.

## Setup (one-time)

### 1. Tasks

Already cloned at `deep-swe/` (115 entries: 113 task dirs + `ugc-*` test fixtures excluded by the batch script + manifest files). To redo:

```bash
git clone https://github.com/datacurve-ai/deep-swe
```

### 2. Pier

```bash
uv tool install datacurve-pier   # or rely on `uv tool run --from datacurve-pier` as the scripts do
```

### 3. Docker

```bash
docker info   # must succeed; each task spins up its own container
```

Tasks declare 2 CPU / 8 GB RAM / 20 GB disk each; pick `CCU` to fit the host (32 GB RAM ≈ CCU 3–4).

## Run

Sampled subset (smoke / quick):

```bash
bash benchmarks/deepswe/run.sh              # 6 tasks, CCU 6
bash benchmarks/deepswe/run.sh 20 8         # 20 tasks, CCU 8
```

Full 113-task corpus in fixed batches (resumes from the first unfinished batch):

```bash
CCU=6 BATCH_SIZE=20 bash benchmarks/deepswe/run_batches.sh
```

Defaults and env-var overrides are listed below. Results land under `jobs/<RUN_ID>/deepswe-*/` (same `jobs/<RUN_ID>/<benchmark>/` layout as the other benchmarks).

## Results

```bash
uv tool run --from datacurve-pier pier view jobs/<RUN_ID>/deepswe-ccu6
jq . jobs/<RUN_ID>/deepswe-ccu6/<job-name>/result.json
```

Per-trial artifacts: `exception.txt`, `result.json`, `trial.log`, `agent/mini-swe-agent.txt`, `verifier/{reward.json,test-stdout.txt}`.

## Resume

Re-running with the same `RUN_ID` (and therefore same `JOBS_DIR`):

- `run_batches.sh` skips any batch whose `result.json` already exists.
- `run.sh` re-samples but writes a fresh job name unless `JOBS_DIR`/`JOB_NAME` are pinned.

## Notes

- `--agent-kwarg model_class=litellm` is mandatory for this endpoint. Without it Pier selects `litellm_response`, mini-swe-agent calls `/v1/responses`, and the endpoint returns `401 Unauthorized`. `litellm` uses `/v1/chat/completions`.
- `MODEL_NAME` in `.env` is stored without the `openai/` prefix (lm-eval convention); the scripts strip and re-add it for litellm, matching `swebench_pro/run.sh` / `scicode/run.sh`.
- The batch script writes fixed task lists to `task_batches/batch_*.txt` (generated on every run, gitignored), filters out `ugc-*` tasks, and errors if the gathered count doesn't equal `MAX_TASKS` (113).

## Scripts

| Script | Purpose |
|---|---|
| `run.sh [N_TASKS] [CCU]` | Sampled subset (seed 0). Default 6 tasks; `CCU` defaults to `N_TASKS`. Override `JOBS_DIR` / `JOB_NAME` via env. |
| `run_batches.sh` | Full corpus in fixed batches, run sequentially, resumable |
| `run_tasks.sh <task-list> [CCU]` | Run an explicit task list (one task name per line). Use it to rerun failed tasks or extend a run: pier cannot grow an existing job's task count. |
| `prune_loop.sh` | Prune finished trials' Docker images (`--once`, `--sweep`) |
| `streaming/` | `sitecustomize.py` + mini-swe-agent patch that stream responses to avoid idle timeouts |

### `run_batches.sh` environment

| Variable | Default | Description |
|---|---|---|
| `BATCH_SIZE` | `20` | Tasks per batch |
| `CCU` | `6` | Parallel tasks within a batch |
| `MAX_TASKS` | `113` | Total tasks to take (after filtering `ugc-*`) |
| `JOBS_DIR` | `jobs/<RUN_ID>/deepswe-batches` | Where results are written |
| `BATCH_DIR` | `task_batches` | Where per-batch task lists are written |
| `PRUNE_DOCKER_AFTER_BATCH` | `0` | `1` = prune stopped containers + unused images after each batch |
| `DOCKER_IMAGE_PRUNE_UNTIL` | `2h` | Min image age for prune when cleanup is on |
| `RUN_ID` | model slug | Campaign id |

Docker cleanup only removes stopped containers and unused images older than
`DOCKER_IMAGE_PRUNE_UNTIL`; build cache is kept so later batches reuse layers.

```bash
# Smoke the batch flow (5 tasks, batches of 2, CCU 2)
MAX_TASKS=5 BATCH_SIZE=2 CCU=2 JOBS_DIR=jobs/<RUN_ID>/deepswe-batch-smoke \
  bash benchmarks/deepswe/run_batches.sh
```

> **CCU ceiling:** each trial uses 2 Docker networks and the daemon's default
> address pool allows ~31, so CCU 16 reliably breaks about half the jobs. Use
> CCU <= 8 unless you enlarge `default-address-pools`.
