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
cd <repo-root>
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
cd <repo-root>
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
bash benchmarks/swebench_pro/run.sh
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
LIMIT=3 STEP_LIMIT=8 WORKERS=3 bash benchmarks/swebench_pro/run.sh

# First 20 instances, full step budget
LIMIT=20 bash benchmarks/swebench_pro/run.sh

# Full run, higher parallelism
WORKERS=8 EVAL_WORKERS=8 bash benchmarks/swebench_pro/run.sh
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
- sweap images set `ENTRYPOINT ["/bin/bash"]`, which swallows the `sleep 2h` arg mini-swe-agent passes to keep the container alive. The config at `benchmarks/swebench_pro/swebench_pro.yaml` sets `run_args: [--rm, --entrypoint, ""]` to clear the entrypoint so `CMD ["sleep","2h"]` runs as PID 1. **Do not remove this** or containers exit immediately.
- Agent config lives at `benchmarks/swebench_pro/swebench_pro.yaml` (cwd `/app`, submit via `git diff --cached`, 250-step / $3 cap). The runner that loads `instances.yaml` and drives mini-swe-agent lives at `benchmarks/swebench_pro/runner.py`.

## Files in this directory

| File | Purpose |
|---|---|
| `run.sh` | Entry point: Phase 1 (patch generation) then Phase 2 (eval) |
| `runner.py` | Loads `instances.yaml` and drives mini-swe-agent |
| `swebench_pro.yaml` | mini-swe-agent config (cwd, submit command, step/cost caps) |
| `prepare_data.sh` | Generates `instances.yaml` and the raw sample at container start, pinned to `SWEBENCH_PRO_HF_REVISION` |
| `prune_loop.sh`, `prune_done_images.py` | Reclaim Docker images of finished instances during a long run |
| `prune_failed_preds.py` | Drop failed/empty predictions so the next run retries them |
| `watch_run.sh` | Live liveness / disk monitor for a running campaign |
| `patches/` | Our patches on top of upstream (`swe-bench-pro/`, `mini-swe-agent/`), applied at image build time |

> The HF dataset moved from 731 to 642 rows and changed its test-name format
> after this section was first written. The image pins the dataset revision
> (see `deployment/README.md`); unpinned local regeneration can score almost
> every instance as failed.
