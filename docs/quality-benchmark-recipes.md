# Quality Benchmark Recipes

Use this sheet to choose and report an eight-benchmark quality run. Counts are fixed, representative samples; `full` means the complete official split. Estimates are initial planning ranges and should be replaced with measured model/endpoint rates.

## Categories

| Category | Benchmarks |
| --- | --- |
| General knowledge | GPQA, MMLU-Pro, HLE |
| Coding | LiveCodeBench, SciCode |
| Agentic coding | BFCL, SWE-bench Pro, DeepSWE |

## Tiers

| Tier | Use | General: GPQA / MMLU-Pro / HLE | Coding: LCB / SciCode | Agentic: BFCL / SWE-Pro / DeepSWE |
| --- | --- | --- | --- | --- |
| Smoke | Wiring and artifact validation | 2 / 2 / 2 | 2 / 2 | 4 / 1 / 1 |
| Balanced | Routine comparison and regression tracking | 50 / 100 / 50 | 50 / 8 | 100 / 10 / 10 |
| Extended | Release candidate and high-confidence comparison | full / 500 / 250 | 200 / 30 | 500 / 50 / 50 |
| Full | Announcement or official competition | full / full / full | full / full | full / full / full |

Use deterministic, stratified manifests for Balanced and Extended; do not use the first N rows. Smoke validates execution only and must not be presented as a quality score.

## Concurrency and planning time

Run benchmarks as separate parallel jobs. A category's wall time is approximately its slowest benchmark, not the sum. Start with these per-benchmark concurrencies:

| Tier | General | Coding | Agentic | Endpoint-wide cap | Expected category wall time |
| --- | --- | --- | --- | --- | --- |
| Smoke | 2-4 | LCB 2-4, SciCode 2 | BFCL 2, SWE/DeepSWE 1 | 8 | General 5-15m; Coding 30-45m; Agentic 30-60m |
| Balanced | GPQA/MMLU 8, HLE 4 | LCB 8, SciCode 4 | BFCL 8, SWE/DeepSWE 2 | 16 | General 1.5-3h; Coding 1-2.5h; Agentic 2.5-6h |
| Extended | GPQA/MMLU 8, HLE 6 | LCB 8-12, SciCode 4-6 | BFCL 12, SWE/DeepSWE 4 | 24 | General 6-12h; Coding 4-8h; Agentic 8-18h |
| Full | 8-16 | LCB 12-16, SciCode 6-8 | BFCL 16, SWE/DeepSWE 4-8 | 32 after load test | 12h to several days |

Concurrency improves throughput only until endpoint saturation. Agent steps within one SWE/DeepSWE task remain sequential. Record p50/p95 latency, tokens, retries, and valid samples/hour so future estimates use observed throughput.

## Main benchmark (default going forward)

Vetted subset+config from the `glm5.2-selfhost-extended` run (model z-ai/glm-5.2 self-host, 2026-09-09/10), reused verbatim for `glm5.3-w4afp8` (2026-09-11/13) so the two campaigns would be comparable. Use this as the standard "main benchmark" for future models instead of re-deriving a manifest per run — it is close to the Extended tier but with each benchmark's subset/CCU tuned from what actually ran clean. Full reports: `jobs/glm5.2-selfhost-extended/README.md`, `jobs/glm5.3-w4afp8/README.md`.

**Launch it with `scripts/run_main_benchmark.sh`** — it encodes every setting in the table/commands below (same subsets, CCU, `MAX_GEN_TOKENS=65536` across all 8 benchmarks) as one script, so a new model's campaign doesn't drift from what actually ran clean here. The per-benchmark commands further down are kept as a reference for what the script does and as a fallback if you need to run/rerun one benchmark by hand.

```bash
RUN_ID=<run-id> bash scripts/run_main_benchmark.sh                  # all 8, sequential by category
RUN_ID=<run-id> bash scripts/run_main_benchmark.sh general coding   # just those categories
```

See the script's header comment for parallel-category launch (one tmux pane per category), why it doesn't pipe stdout through `tee`, and the infra-vs-model failure rerun policy.

| Benchmark | Subset used | CCU | Measured wall clock | Note |
| --- | --- | --- | --- | --- |
| GPQA Diamond | full 198 questions, 5-shot CoT | 8 | ~58m | stable, reuse as is |
| MMLU-Pro | 36 questions/subject (504/~11,000), 14 subjects | 8 | ~37m | subsampled due to cost limits, does not fully represent each small subject |
| HLE | 250/2,500 questions (Extended tier, text-only) | 6 (generate) / 6 (judge) | ~4h49m generate + ~5m judge | scored by an LLM judge (deepseek-v4-pro), not raw string match — see [[HLE note]] |
| LiveCodeBench | codegeneration scenario, 199 problems, pass@1 (n=1, temp 0) | 4 | not logged (only the end timestamp exists) | add a start-time log in future runs |
| SciCode | without_background split, 30 problems | 8 | ~1h58m | scores both sub-steps and full problems; a large gap between them is normal |
| BFCL v4 | all 13/13 single-turn categories (7 non-live + 6 live), no multi-turn/agentic | 4 (script default) | ~37m | CCU can be raised (the script default is low, the limit has not been tested) |
| SWE-bench Pro | full 200 instances | 4 (agent) / 4 (eval) | ~11h36m | longest benchmark, takes most of the total wall clock |
| DeepSWE | full 64 tasks | **8** (not 16) | ~5h30m when run sequentially at CCU 8 | CCU 16 exhausts the Docker network pool and fails ~1/3 of trials (see [[deepswe-ccu-docker-network-limit]]) — CCU 8 is fixed for future runs, do not repeat this mistake |

**Total wall clock if categories run in parallel** (as recommended above): General (GPQA/MMLU-Pro/HLE) ~4h49m (HLE is the longest), Coding (LCB/SciCode) ~1h58m, Agentic (BFCL/SWE-Pro/DeepSWE) ~11h36m (SWE-bench Pro is the longest) — about 11h36m total with all 3 categories in parallel if the endpoint has capacity for all 3 at once, or ~18h cumulative if categories run sequentially.

### Per-benchmark commands

Run from `<repo-root>` after `source .env` (`OPENAI_BASE_URL`, `API_KEY`). Change `RUN_ID`/model to match the model under test. Commands marked **(reconstructed)** are inferred from the scripts + recorded config (`results_*.json`/`config.json`); no job.log recorded the original command, so verify the flags before using them for a new model. Commands marked **(confirmed)** are taken verbatim from job.log.

```bash
# GPQA Diamond — full 198 questions, CCU 8 (reconstructed)
RUN_ID=<run-id> NUM_CONCURRENT=8 MAX_GEN_TOKS=65536 REQUEST_TIMEOUT=3600 \
  bash benchmarks/gpqa/run.sh

# MMLU-Pro — 36 questions/subject (504 total), CCU 8 (reconstructed)
RUN_ID=<run-id> NUM_CONCURRENT=8 MAX_GEN_TOKS=65536 REQUEST_TIMEOUT=3600 LIMIT=36 \
  bash benchmarks/mmlu_pro/run.sh

# HLE — 250/2,500 questions (125/subtask x 2), CCU 6, generate + judge automatically (reconstructed for the generate part,
# confirmed for the separate judge command in JUDGE.md)
RUN_ID=<run-id> NUM_CONCURRENT=6 MAX_GEN_TOKS=65536 LIMIT=125 REQUEST_TIMEOUT=3600 \
  bash benchmarks/hle/run.sh
# to run the judge separately (generations already exist):
RUN_ID=<run-id> ./benchmarks/hle/judge.sh                                # primary judge: deepseek/deepseek-v4-pro
RUN_ID=<run-id> JUDGE_MODEL=qwen/qwen3.7-plus ./benchmarks/hle/judge.sh   # cross-check judge
RUN_ID=<run-id> JUDGE_MODEL=<model under test> ./benchmarks/hle/judge.sh   # self-judge to check bias

# LiveCodeBench — codegeneration scenario, LIMIT=200 (result is n=199 because 1 problem was dropped), MULTIPROCESS=8
# (confirmed from tmux scrollback, sweep 2026-09-10 — previously mislabeled as CCU unconfirmed)
RUN_ID=<run-id> LIMIT=200 MULTIPROCESS=8 \
  bash benchmarks/livecodebench/run.sh

# SciCode — without_background split, 30 problems, CCU 8, SAMPLE_SHUFFLE=42 (fixed seed so the manifest is reproducible)
# (confirmed from tmux scrollback, sweep 2026-09-10 — previously missing SAMPLE_SHUFFLE/MAX_GEN_TOKENS)
RUN_ID=<run-id> LIMIT=30 MAX_CONNECTIONS=8 SAMPLE_SHUFFLE=42 MAX_GEN_TOKENS=65536 \
  bash benchmarks/scicode/run.sh

# BFCL v4 — all 13/13 single-turn categories, CCU 4 (reconstructed; the TEST_CATEGORY/NUM_THREADS actually
# used could not be confirmed — the tmux history-limit of 2000 lines scrolled away the original command of the glm5.2-selfhost-extended run;
# re-check category_mapping.py before running for a new model)
RUN_ID=<run-id> TEST_CATEGORY=single_turn \
  bash benchmarks/bfcl/run.sh

# SWE-bench Pro — first 200 instances (LIMIT=200, full is 731), CCU 4 agent / 4 eval (reconstructed from
# run_config.yaml + README — the original command also scrolled out of tmux history because the log was too long, see the BFCL note above)
RUN_ID=<run-id> WORKERS=4 EVAL_WORKERS=4 LIMIT=200 \
  bash benchmarks/swebench_pro/run.sh

# DeepSWE — full 64 tasks, merged from 3 batches run sequentially (NOT a single "64 8" command — corrected after
# sweeping tmux; the old doc was wrong). Batch 1 used run.sh (the first N tasks in the default order); batches 2/3 used
# run_tasks.sh with specific task lists to rerun exactly the failed part. The task list is a plain text file,
# one task name per line (e.g. <your-task-list>.txt). All 3 lines below were (confirmed from the
# tmux scrollback of session deepswe-maas); the original list files are no longer in the repo.
RUN_ID=<run-id> MAX_GEN_TOKENS=65536 \
  bash benchmarks/deepswe/run.sh 32 8                                          # batch 1: first 32 tasks, CCU 8
RUN_ID=<run-id> MAX_GEN_TOKENS=65536 JOB_NAME=tasks33-64-ccu16 \
  bash benchmarks/deepswe/run_tasks.sh <your-task-list>.txt 16                 # batch 2: tasks 33-64, CCU 16 — 10/32 failed from the network pool
RUN_ID=<run-id> MAX_GEN_TOKENS=65536 JOB_NAME=rerun10-ccu8 \
  bash benchmarks/deepswe/run_tasks.sh <your-task-list>.txt 8                  # batch 3: rerun exactly the 10 failed tasks at CCU 8
# Recommendation for future runs: skip the mid-way CCU 16 batch and run all 64 tasks at CCU 8 from the start
# (see [[deepswe-ccu-docker-network-limit]]) — the 3 batches above are the real history of what was run, not something to repeat.
```

### Per-category commands (sequential within each category, an earlier failure does not block later ones)

Each category runs its benchmarks **sequentially**, joined with **`;`** instead of `&&` — the next benchmark still runs even if the previous one fails (exit ≠ 0). Reason for the change: on 2026-09-11 GPQA crashed midway (the endpoint cut the SSE stream after ~15 minutes → TransferEncodingError after retries were exhausted), which killed the whole `&&` chain, so MMLU-Pro/HLE never ran. Therefore, after a run you must check each benchmark's output in `jobs/<run-id>/` yourself — a `;` chain no longer reports an overall failure. Note: `;` only protects against *failures*; Ctrl+C midway still stops the whole chain as usual. The 3 categories can run in parallel if the endpoint can handle the load (see the CCU/cap table above).

```bash
# ── Category: General knowledge (GPQA -> MMLU-Pro -> HLE) ──
RUN_ID=<run-id> NUM_CONCURRENT=8 MAX_GEN_TOKS=65536 REQUEST_TIMEOUT=3600 \
  bash benchmarks/gpqa/run.sh ; \
RUN_ID=<run-id> NUM_CONCURRENT=8 MAX_GEN_TOKS=65536 REQUEST_TIMEOUT=3600 LIMIT=36 \
  bash benchmarks/mmlu_pro/run.sh ; \
RUN_ID=<run-id> NUM_CONCURRENT=6 MAX_GEN_TOKS=65536 LIMIT=125 REQUEST_TIMEOUT=3600 \
  bash benchmarks/hle/run.sh

# ── Category: Coding (LiveCodeBench -> SciCode) ──
RUN_ID=<run-id> LIMIT=200 MULTIPROCESS=8 \
  bash benchmarks/livecodebench/run.sh ; \
RUN_ID=<run-id> LIMIT=30 MAX_CONNECTIONS=8 SAMPLE_SHUFFLE=42 MAX_GEN_TOKENS=65536 \
  bash benchmarks/scicode/run.sh

# ── Category: Agentic coding (BFCL -> SWE-bench Pro -> DeepSWE) ──
RUN_ID=<run-id> TEST_CATEGORY=single_turn MAX_GEN_TOKENS=65536 \
  bash benchmarks/bfcl/run.sh ; \
RUN_ID=<run-id> WORKERS=4 EVAL_WORKERS=4 LIMIT=200 MAX_GEN_TOKENS=65536 \
  bash benchmarks/swebench_pro/run.sh ; \
RUN_ID=<run-id> MAX_GEN_TOKENS=65536 bash benchmarks/deepswe/run.sh 64 8
```

**Note:** BFCL is placed first in the Agentic category because it is the fastest, and DeepSWE last so CCU 8 can be settled once you are free to monitor it (SWE-bench Pro runs longest, ~11h36m, so it is the bottleneck of this category, not the ordering). Here DeepSWE is written compactly as a single `64 8` command (run the full 64 tasks at CCU 8 from the start) — different from the real history (3 batches at CCU 8/16/8 because CCU was being probed midway, see the "Per-benchmark commands" section above); use this compact version for new models, since CCU 8 is confirmed as the safe level and there is no need to probe CCU 16 again. Before running for a new model, do a trial run at the Smoke tier to confirm the flags above are still valid for the current script version — GPQA/MMLU-Pro/BFCL/SWE-bench Pro are still **(reconstructed)** because the original commands of the `glm5.2-selfhost-extended` run scrolled out of tmux history (history-limit 2000 lines, log too long) when re-swept on 2026-09-10; LiveCodeBench and SciCode were re-**(confirmed)** from the tmux scrollback.

## Decision and report

- **Decision:** category, tier, reason, model, endpoint, sample-manifest version, per-benchmark concurrency, endpoint cap.
- **Report:** run URL/ID, commit, samples requested/valid/failed, score, wall time, token usage/cost, retry/error rate, and artifact link.
- **Comparison gate:** same dataset revision, manifest, prompt/harness revision, generation settings, scorer, and tier.
- **Promotion:** Smoke passed -> Balanced; Balanced stable -> Extended; Extended reviewed -> Full.

Full results are the only announcement-grade results. Any partial, retried, or non-comparable run must be labeled explicitly.
