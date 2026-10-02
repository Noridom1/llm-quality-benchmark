# LLM Quality Benchmarks

Benchmark harnesses for evaluating LLMs against an OpenAI-compatible endpoint.
Each benchmark lives under its own directory with a `scripts/run_*.sh` wrapper.

| Benchmark | Script | Type | Sandbox |
|---|---|---|---|
| GPQA-Diamond | `scripts/run_gpqa.sh` | Reasoning MCQ | None |
| MMLU-Pro | `scripts/run_mmlu_pro.sh` | Reasoning MCQ | None |
| HLE | `scripts/run_hle.sh` | Reasoning QA | None |
| SciCode | `scripts/run_scicode.sh` | Scientific coding | Sandboxed Python |
| LiveCodeBench | `scripts/run_livecodebench.sh` | Competitive coding | Sandboxed tests |
| BFCL v4 | `scripts/run_bfcl.sh` | Function/tool-calling | None (AST) |
| SWE-bench Pro | `scripts/run_swebench_pro.sh` | Agent SE | Docker per instance |
| DeepSWE | `scripts/run_deepswe.sh`, `scripts/run_deepswe_batches.sh` | Agent SE | Docker per task |

## Common setup

```bash
cd /home/stackops/benchmark
cp .env.example .env
```

Fill in `.env`:

- `API_KEY` — your OpenAI-compatible API key.
- `OPENAI_BASE_URL` — endpoint base, keep `/v1`.
- `MODEL_NAME` — model id with `openai/` prefix (e.g. `openai/z-ai/glm-5.2`); scripts strip the prefix.
- `HF_TOKEN` — HuggingFace read token (required for gated datasets like GPQA).
- `HLE_MAIN_JUDGE` — optional; model that grades HLE and produces the score
  (default `deepseek/deepseek-v4-pro`). Must differ from `MODEL_NAME` — a model
  grading its own answers is not a defensible score, and `scripts/judge_hle.sh`
  refuses to do it.
- `HLE_SECOND_JUDGE` — optional; independent cross-check judge
  (default `qwen/qwen3.7-plus`). Set to empty to run only one judge.
- `HLE_SELF_JUDGE` — optional; `1` (default) also has the model under test grade
  itself, to measure self-judging bias. Never a number to report; set `0` to skip.
- `HLE_JUDGE_BASE_URL` / `HLE_JUDGE_API_KEY` — optional; endpoint and key serving
  the independent HLE judges, for when the endpoint under test doesn't serve them
  (e.g. a self-hosted single-model deployment). Both default to `OPENAI_BASE_URL` /
  `API_KEY`. The self-judge always uses the main endpoint.

## HLE grading

`scripts/run_hle.sh` generates answers, prints lm-eval's string-match table, and
then re-grades with an LLM judge the way upstream HLE does. **The judged number
is the score; the lm-eval table is a floor.** On the extended glm-5.2 run the two
differ by 5.6pp overall (32.4% string match vs 38.0% judged), because answers
that are correct but phrased differently from the target string score zero under
string match.

Three judges run over the same cached responses, so this costs judge tokens
only — answers are never regenerated:

| Role | Default | Purpose |
|---|---|---|
| `HLE_MAIN_JUDGE` | `deepseek/deepseek-v4-pro` | **Produces the score.** |
| `HLE_SECOND_JUDGE` | `qwen/qwen3.7-plus` | Independent cross-check: shows the score is not an artefact of one judge. |
| `HLE_SELF_JUDGE=1` | `MODEL_NAME` | Self-judging bias check. **Never reported.** |

`scripts/compare_judges.py` then prints each judge's score plus pairwise
agreement and Cohen's kappa, and writes `judges_comparison.json`. Scores are
shown twice: over all docs a judge graded, and over the docs *every* judge
graded — judges differ in how many verdicts they fail to parse, so the common
set is the only fair basis for comparing them.

```bash
RUN_ID=my-run ./scripts/run_hle.sh                    # generate + 3 judges + comparison
HLE_SELF_JUDGE=0 RUN_ID=my-run ./scripts/run_hle.sh   # skip the self-judge pass
HLE_SECOND_JUDGE= RUN_ID=my-run ./scripts/run_hle.sh  # one judge only
SKIP_JUDGE=1 RUN_ID=my-run ./scripts/run_hle.sh       # generate only (floor, do not report)
RUN_ID=my-run SRC_SUBDIR=hle ./scripts/judge_hle.sh   # judge an existing run
```

Judge verdicts are cached in sqlite, so re-scoring an already-judged run is free
(`OFFLINE=1` scores from cache with no network). Note the self-judge pass is the
slow one: on the extended glm-5.2 run it took 875s against deepseek's 307s, and
left 7/250 verdicts unparseable because the model kept trying to solve the
question instead of grading it.

See `BENCHMARK_TIMES.md` for run-time estimates and subset commands.

---

# SWE-bench Pro

Run the [SWE-bench Pro](https://huggingface.co/datasets/ScaleAI/SWE-bench_Pro) agent benchmark (731 public instances) against an OpenAI-compatible endpoint. Two-phase: an agent scaffold drives the model to produce a patch per instance, then each patch is applied + graded in a pristine Docker container.

## Architecture

- **Phase 1 — Patch generation**: [mini-swe-agent](https://github.com/SWE-agent/mini-swe-agent) drives the model as a bash-only agent inside a per-instance Docker container (`jefzda/sweap-images:<tag>`) and submits a `git diff --cached` patch. We use mini-swe-agent instead of the official SWE-agent/SWE-Rex scaffold because SWE-Rex's glibc-based standalone-Python builder fails on the sweap images (glibc 2.31/2.36 < 2.38). mini-swe-agent only needs `docker exec` + bash, so it works with any image.
- **Phase 2 — Evaluation**: `swe_bench_pro_eval.py` applies each patch in a fresh container, runs the instance's fail2pass + pass2pass tests, and reports Pass@1. Runs locally via `--use_local_docker` (no Modal account needed).

## Setup (one-time)

### 1. Clone the harness with submodules

Already done at `SWE-bench_Pro-os/` (submodules `SWE-agent` + `mini-swe-agent` included). To redo:

```bash
git clone --recurse-submodules https://github.com/scaleapi/SWE-bench_Pro-os.git
```

### 2. Create the venv and install dependencies

```bash
cd /home/stackops/benchmark
uv venv .venv-swebenchpro --python 3.11
uv pip install --python .venv-swebenchpro/bin/python -r SWE-bench_Pro-os/requirements.txt
uv pip install --python .venv-swebenchpro/bin/python -e SWE-bench_Pro-os/SWE-agent
uv pip install --python .venv-swebenchpro/bin/python -e SWE-bench_Pro-os/mini-swe-agent
```

SWE-bench Pro needs Python ≥ 3.11 (SWE-agent requirement); mini-swe-agent is the scaffold actually used at run time. The SWE-agent package is installed only to satisfy the repo's `requirements.txt` and provide `generate_sweagent_instances.py`'s imports.

### 3. Generate the instances manifest

```bash
cd SWE-bench_Pro-os
../.venv-swebenchpro/bin/python helper_code/generate_sweagent_instances.py --dockerhub_username jefzda
```

Writes `SWE-agent/data/instances.yaml` (731 entries, each with the correct `jefzda/sweap-images:<tag>` image name). The `dockerhub_username` is `jefzda` — the public, shared image repository; do not change it unless you've mirrored the images under your own account.

### 4. Cache the raw sample for evaluation

```bash
cd /home/stackops/benchmark
.venv-swebenchpro/bin/python - <<'PY'
import json, os
from datasets import load_dataset
os.environ.setdefault("HF_TOKEN", open(".env").read().split("HF_TOKEN=")[1].split()[0])
ds = load_dataset("ScaleAI/SWE-bench_Pro", split="test")
out = "SWE-bench_Pro-os/data/swebench_pro_raw_sample.jsonl"
os.makedirs("SWE-bench_Pro-os/data", exist_ok=True)
with open(out, "w") as f:
    for row in ds:
        f.write(json.dumps({k: (v if isinstance(v, (str, int, float, bool)) or v is None else json.dumps(v)) for k, v in row.items()}) + "\n")
print(f"Wrote {len(ds)} rows to {out}")
PY
```

This JSONL (with lowercase `fail_to_pass`/`pass_to_pass` columns) is what `swe_bench_pro_eval.py --raw_sample_path` reads. The repo ships `helper_code/sweap_eval_full_v2.jsonl` but it uses uppercase column names that the eval script doesn't read; exporting from HF avoids that mismatch.

### 5. Docker

Docker must be installed and the daemon running. The script pulls each `jefzda/sweap-images:<tag>` on demand (1–3 GB per image). For a smoke test, pre-pull a few:

```bash
docker pull jefzda/sweap-images:nodebb.nodebb-NodeBB__NodeBB-04998908ba6721d64eba79ae3b65a351dcfbc5b5
```

## Run

```bash
bash scripts/run_swebench_pro.sh
```

Defaults: 731 instances, 4 Phase-1 workers, 4 Phase-2 workers, 250 agent steps / $3 cost limit per instance, results in `jobs/<RUN_ID>/swebench-pro/`.

### Options (set as env vars before the command)

| Variable | Default | Description |
|---|---|---|
| `LIMIT` | _empty_ | First N instances (smoke test). Empty = full 731. |
| `WORKERS` | `4` | Parallel Phase-1 agent containers (each = 1 docker container + 1 model stream) |
| `EVAL_WORKERS` | `4` | Parallel Phase-2 eval containers |
| `STEP_LIMIT` | `250` | Max agent turns per instance |
| `COST_LIMIT` | `3.0` | Max model spend per instance (USD) |
| `REDO_EXISTING` | `0` | `1` = re-run Phase 1 for instances already in `preds.json` |
| `REDO_EVAL` | `0` | `1` = re-run Phase 2 for instances with an existing output |
| `DOCKERHUB_USERNAME` | `jefzda` | sweap images host (public/shared) |
| `RUN_ID` | _model slug_ | Campaign id; artifacts land in `jobs/<RUN_ID>/swebench-pro/` |

Examples:

```bash
# 3-instance smoke test (few steps, just validates plumbing)
LIMIT=3 STEP_LIMIT=8 WORKERS=3 bash scripts/run_swebench_pro.sh

# First 20 instances, full step budget
LIMIT=20 bash scripts/run_swebench_pro.sh

# Full run, higher parallelism
WORKERS=8 EVAL_WORKERS=8 bash scripts/run_swebench_pro.sh
```

## Results

Written to `jobs/<RUN_ID>/swebench-pro/`:

- `preds/preds.json` — per-instance `{model_name_or_path, instance_id, model_patch}` (Phase-1 output).
- `preds/<instance_id>/<instance_id>.traj.json` — full agent trajectory (messages, actions, observations).
- `patches.json` — Phase-1 patches reshaped into the list format the eval script expects.
- `eval/eval_results.json` — `{instance_id: bool}` Pass@1 verdict.
- `eval/<instance_id>/` — per-instance `{agent,workspace}/{stdout,stderr,output.json,patch.diff,entryscript.sh,run_script.sh,parser.py}`.

The script prints a final `Pass@1: p/n (xx.x%)` summary.

```bash
jq . jobs/<RUN_ID>/swebench-pro/eval/eval_results.json
```

## Resume

Re-running with the same `RUN_ID` resumes:

- **Phase 1**: mini-swe-agent skips any instance already in `preds.json` (set `REDO_EXISTING=1` to override).
- **Phase 2**: `swe_bench_pro_eval.py` skips instances with an existing `agent_output.json` (set `REDO_EVAL=1` to override).

## Notes

- The official SWE-agent scaffold (with SWE-Rex `--instances.deployment.type=docker`) does **not** work with the `jefzda/sweap-images` because SWE-Rex rebuilds Python 3.11 against the builder's glibc (2.38) and the copy fails on the target images' older glibc (2.31/2.36) with `GLIBC_2.38 not found`. mini-swe-agent sidesteps this by using `docker exec` + the image's own toolchain — no Python rebuild.
- sweap images set `ENTRYPOINT ["/bin/bash"]`, which swallows the `sleep 2h` arg mini-swe-agent passes to keep the container alive. The config at `tasks/swebench-pro/swebench_pro.yaml` sets `run_args: [--rm, --entrypoint, ""]` to clear the entrypoint so `CMD ["sleep","2h"]` runs as PID 1. **Do not remove this** or containers exit immediately.
- Agent config lives at `tasks/swebench-pro/swebench_pro.yaml` (cwd `/app`, submit via `git diff --cached`, 250-step / $3 cap). The runner that loads `instances.yaml` and drives mini-swe-agent lives at `tasks/swebench-pro/run_swebench_pro.py`.

---

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
bash scripts/run_deepswe.sh              # 6 tasks, CCU 6
bash scripts/run_deepswe.sh 20 8         # 20 tasks, CCU 8
```

Full 113-task corpus in fixed batches (resumes from the first unfinished batch):

```bash
CCU=6 BATCH_SIZE=20 bash scripts/run_deepswe_batches.sh
```

Defaults and env-var overrides are documented in [`scripts/README.md`](scripts/README.md). Results land under `jobs/<RUN_ID>/deepswe-*/` (same `jobs/<RUN_ID>/<benchmark>/` layout as the other benchmarks).

## Results

```bash
uv tool run --from datacurve-pier pier view jobs/<RUN_ID>/deepswe-ccu6
jq . jobs/<RUN_ID>/deepswe-ccu6/<job-name>/result.json
```

Per-trial artifacts: `exception.txt`, `result.json`, `trial.log`, `agent/mini-swe-agent.txt`, `verifier/{reward.json,test-stdout.txt}`.

## Resume

Re-running with the same `RUN_ID` (and therefore same `JOBS_DIR`):

- `run_deepswe_batches.sh` skips any batch whose `result.json` already exists.
- `run_deepswe.sh` re-samples but writes a fresh job name unless `JOBS_DIR`/`JOB_NAME` are pinned.

## Notes

- `--agent-kwarg model_class=litellm` is mandatory for this endpoint. Without it Pier selects `litellm_response`, mini-swe-agent calls `/v1/responses`, and the endpoint returns `401 Unauthorized`. `litellm` uses `/v1/chat/completions`.
- `MODEL_NAME` in `.env` is stored without the `openai/` prefix (lm-eval convention); the scripts strip and re-add it for litellm, matching `run_swebench_pro.sh` / `run_scicode.sh`.
- The batch script writes fixed task lists to `task_batches/batch_*.txt`, filters out `ugc-*` tasks, and errors if the gathered count doesn't equal `MAX_TASKS` (113).
