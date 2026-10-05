# Scripts

Cross-benchmark orchestration and monitoring. Anything that belongs to a single
benchmark lives in [`../benchmarks/<name>/`](../benchmarks/README.md) instead.

All scripts `cd` to the repo root and read `.env` themselves
(`API_KEY`, `OPENAI_BASE_URL`, `MODEL_NAME`).

| Script | Purpose |
|---|---|
| `setup_upstream.sh` | One-time setup for **direct** runs (no Docker): clones each benchmark's upstream at its pinned commit, applies our patch series and builds the venv — mirroring the Dockerfile stages. Targets: `bfcl lcb scicode swebenchpro lmeval` or `all`. See the "Direct-run setup" table in the root README. |
| `run_main_benchmark.sh` | The vetted "main benchmark" recipe (fixed subset sizes and CCU), run by category: `general` (GPQA, MMLU-Pro, HLE), `coding` (LiveCodeBench, SciCode, BFCL), `agentic` (SWE-bench Pro, DeepSWE). Exits non-zero if any step failed. See its header and [`docs/quality-benchmark-recipes.md`](../docs/quality-benchmark-recipes.md). This is the image's default command. |
| `run_general_balanced.sh` | Alternate "Balanced tier" recipe for GPQA / MMLU-Pro / HLE (smaller counts, CCU 2). |
| `run_all_smoke_sequential.sh` | Sequential smoke test across all 8 benchmarks, with retry and cooldown for rate-limited endpoints. |
| `progress.sh` | One-shot progress check across `jobs/<RUN_ID>/`. |

```bash
RUN_ID=my-model bash scripts/run_main_benchmark.sh                  # all 3 categories
RUN_ID=my-model bash scripts/run_main_benchmark.sh general coding   # chosen categories
RUN_ID=my-model bash scripts/run_all_smoke_sequential.sh            # quick end-to-end check
bash scripts/progress.sh
```

Benchmark-specific helpers (judges, pruners, retries, watchers) are documented in
each benchmark's README, for example
[`benchmarks/swebench_pro/`](../benchmarks/swebench_pro/README.md) for the disk
pruner and run watcher, and [`benchmarks/hle/`](../benchmarks/hle/README.md) for
judging.
