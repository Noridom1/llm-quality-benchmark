# Benchmark Run Time Estimates

All estimates are for **GLM-5.2** via GreenNode API (`z-ai/glm-5.2`), with default
concurrency settings. Actual times vary with API latency, response length, and
evaluation timeouts.

| Benchmark | Script | Problems | Concurrency | Full Run Est. | Subset (20) Est. | Notes |
|---|---|---|---|---|---|---|
| GPQA-Diamond | `run_gpqa.sh` | 198 | `NUM_CONCURRENT=4` | ~20 min | ~2 min | 0-shot MCQ, regex eval, no sandbox |
| MMLU-Pro | `run_mmlu_pro.sh` | 12,032 | `NUM_CONCURRENT=4` | ~22 hours | ~2 min | 5-shot CoT, 14 subtasks; `LIMIT=20` = 280 Qs (20/subtask) |
| HLE | `run_hle.sh` | 2,158 | `NUM_CONCURRENT=4` | ~4.5 hours | ~5 min | 0-shot, 2 subtasks; `LIMIT=20` = 40 Qs (20/subtask) |
| SciCode | `run_scicode.sh` | 288 subproblems | `MAX_CONNECTIONS=4` | ~5.5 hours | ~23 min | `inspect_ai` + sandboxed Python exec; `LIMIT=20` = 20 main problems |
| LiveCodeBench | `run_livecodebench.sh` | 1,055 | `MULTIPROCESS=4` | ~8 hours | ~15 min | Code gen + sandboxed test exec; `LIMIT=20` = 20 problems |
| BFCL v4 | `run_bfcl.sh` | ~2,000 (scoring) | `NUM_THREADS=4` | ~1.5 hours | <1 min | AST-match; default smoke set = 5 cats (~1,040); `TEST_CATEGORY=all_scoring` = full |
| SWE-bench Pro | `run_swebench_pro.sh` | 731 | `WORKERS=4` | ~45 hours | ~30 min | 2-phase agent + docker eval; `LIMIT=20` = 20 instances |
| DeepSWE | `run_deepswe_batches.sh` | 113 | `CCU=4` | ~29 hours | ~5 hours | Pier + mini-swe-agent, docker per task; ~1 hr/task observed; subset via `run_deepswe.sh 20 4` |

## Methodology

- **GPQA**: Previously smoke-tested; 198 Qs at ~6s/Q with 4 concurrent = ~20 min.
- **MMLU-Pro**: 12,032 Qs at ~6s/Q with 4 concurrent = ~22 h. Largest benchmark.
- **HLE**: 2,158 text-only Qs (filtered from 2,500) at ~6s/Q with 4 concurrent = ~4.5 h.
- **SciCode**: 288 subproblems with sandboxed execution; ~70s/subproblem avg at 4 concurrent = ~5.5 h.
- **LiveCodeBench**: Smoke test measured ~56s/problem at `MULTIPROCESS=2` (generation + eval).
  At `MULTIPROCESS=4`, estimated ~30s/problem. 1,055 problems = ~8.8 h.
  Generation dominates; eval is ~1-2s/problem.
- **SWE-bench Pro**: 2-phase. Phase 1 (agent) ~3-4 min/instance at `WORKERS=4` (250-step cap,
  ~7s/step LLM + shell). Phase 2 (eval) ~45s/instance (apply patch + run fail2pass/pass2pass
  tests in a pristine container). 731 instances ≈ 731×3.5min/4 + 731×45s/4 ≈ 43h Phase 1 +
  ~2h Phase 2. Subset (20) ≈ 20×3.5min/4 + 20×45s/4 ≈ 18min + 4min ≈ 22min; smoke run
  measured ~30min including image pulls.
- **DeepSWE**: 113 tasks, Pier + `mini-swe-agent` in per-task Docker. Each task ~1 hr end-to-end observed
  (agent solve loop + verifier container). At CCU 4: full run = ceil(113/4)×1 h ≈ 29 h (plus image
  builds + setup overhead). Subset (20) = ceil(20/4)×1 h ≈ 5 h.

## Subset Commands

```bash
# GPQA: first 20
LIMIT=20 bash scripts/run_gpqa.sh

# MMLU-Pro: first 20 per subtask (280 total)
LIMIT=20 bash scripts/run_mmlu_pro.sh

# HLE: first 20 per subtask (40 total)
LIMIT=20 bash scripts/run_hle.sh

# SciCode: first 20 main problems
LIMIT=20 bash scripts/run_scicode.sh

# LiveCodeBench: first 20 problems
LIMIT=20 bash scripts/run_livecodebench.sh

# SWE-bench Pro: first 20 instances
LIMIT=20 bash scripts/run_swebench_pro.sh

# DeepSWE: 20-task sample (CCU 4)
bash scripts/run_deepswe.sh 20 4
```

## Reducing Wall Time

Increase concurrency to cut wall time (at the cost of higher API load):

```bash
NUM_CONCURRENT=8  bash scripts/run_gpqa.sh        # ~10 min
NUM_CONCURRENT=16 bash scripts/run_mmlu_pro.sh    # ~5.5 hours
MULTIPROCESS=8    bash scripts/run_livecodebench.sh  # ~4 hours
WORKERS=8 EVAL_WORKERS=8 bash scripts/run_swebench_pro.sh  # ~15 hours
CCU=8                bash scripts/run_deepswe_batches.sh  # ~15 hours
```
