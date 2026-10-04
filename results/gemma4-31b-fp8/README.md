# Benchmark results — gemma4-31b-fp8

Model: `google/gemma-4-31b-it` self-host, **FP8** quantized. Run date: 2026-09-14/17
(multiple reruns due to infrastructure incidents — details in each section below).

**Compared with:**
[glm5.2-selfhost-extended](../glm5.2-selfhost-extended/README.md) (baseline, the
unquantized model) and [glm5.3-w4afp8](../glm5.3-w4afp8/README.md) (a different model, same z-ai family,
W4A-FP8 quantized).

**Summary first:** gemma4-31b-fp8 is far weaker on the 2 multi-step agentic/coding benchmarks
(SWE-bench Pro, DeepSWE) than both glm baselines, while on single-turn
knowledge/QA benchmarks (GPQA, MMLU-Pro) it is only moderately lower. This is the clearest
capability gap observed between campaigns in this project.

## SWE-bench Pro

Fixing real bugs/features in real codebases (agentic coding, multi-step, graded by running real tests).

**Subset:** full 200/731 instances (SWE-bench Pro has 731 instances in total; these are the first 200
by index, identical to both baselines).

76/200 instances (38%) hit infrastructure errors in Phase 1: the agent container's `docker run` failed to
start (exit 125), the agent never ran, so the "patch" is actually Python subprocess error text —
confirmed directly by reading the `model_patch` contents in `preds.json`,
not relying on aggregate logs (see [[swebench-pro-metric-pitfalls]]). Exactly these 76
instances were rerun using a `--filter` regex matching exactly the 76 `instance_id`s (without touching the other 124
instances), in tmux `gemma4-swebenchpro-rerun76`.

| Metric | Result |
|---|---|
| Pass@1 | **45/200 = 22.5%** |
| Avg turns/instance | **12.70** (199/200 instances have a valid trajectory) — counted from `api_calls`, matching 100% the number of `role=="assistant"` messages in the sampled check |
| Total tokens | **~24.68M** (23.57M prompt + 1.11M completion), 2,528 API calls |
| CCU | 4 (agent) / 4 (eval) |
| MAX_GEN_TOKENS | 32768 |
| Wall clock | *(no clean number — 2 separate windows due to the rerun)*: original run 2026-09-15 06:31→07:48 (~1h17m, 124/200 done), 76-instance rerun 2026-09-16 09:39→10:30 (~52m) |

**Note:** after the rerun, 75/76 instances have a real patch. The remaining 1/76
(`instance_protonmail__webclients-0200ce0fc1d4dbd35178c10d440a284c82ecc858`) hit
`ContextWindowExceededError` — this is a genuine model/task failure (exceeding the context limit),
not infrastructure, so it is still counted as a failure per
[[benchmark-failure-attribution]]. In addition there is a group of `False` instances where the patch did not
compile (Go build error, Python import error, JS test setup fail) — genuine
model failures, not excluded from the denominator. Compared with the glm5.2 baseline (109/200 = 54.50%) and glm5.3
(133/200 = 66.5%), gemma4-31b-fp8 is much lower (**-32 points** vs glm5.2,
**-44 points** vs glm5.3).

## DeepSWE

Similar to SWE-bench Pro but with synthetic tasks (datacurve), graded by the rate of fail→pass
(f2p) and pass→pass (p2p) tests in a Docker sandbox.

**Subset:** full **64/113 tasks** (random subset with a fixed seed, same as both baselines), merged from
4 original batches (`deepswe-batches/batch_00..03`, CCU 4) + 1 rerun batch of 58 failed tasks
(`deepswe/failed58-ccu4`, CCU 4), merged at
`jobs/gemma4-31b-fp8/deepswe/64tasks-merged/MERGE_SUMMARY.json`.

Of the 64 tasks, **44 trials have real data** (ran clean from start to finish, not interrupted
midway by infrastructure); the remaining 20 trials were excluded from the denominator due to infrastructure errors per
[[benchmark-failure-attribution]]:
- 18 trials were blocked by the model gateway's content/keyword filter (a new infrastructure
  error discovered in this campaign — `Request blocked due to detected keyword`)
- 1 trial `VerifierTimeoutError` (verifier docker ran over 1800s, no reward.json)
- 1 original trial hit `AuthenticationError` (401) from the initial batch_00 run

| Metric | Result |
|---|---|
| Reward (task fully passed) | **0/44 = 0.0%** |
| Avg turns/task | **42.91** (counted from `n_agent_steps`, matching the number of `role=="assistant"` messages in the trajectory) |
| f2p (fail→pass) | **12.41%** (334/2,692) |
| p2p (pass→pass, did not break old tests) | **47.04%** (64,128/136,333) |
| Total tokens (44 valid trials) | **~56.78M** (55.94M prompt of which 43.23M cached + 0.84M completion) |
| CCU | 4 (`n_concurrent_trials`, all 5 batches) |
| MAX_GEN_TOKENS | 65536 (matches all 5 batches, confirmed directly from each task's config) |
| Wall clock | **~6h57m35s** (cumulative total of 5 batches run sequentially: 1h06m37s + 1h22m31s + 23m22s + 35s + 4h04m30s) |

**Note:** this is a strong and consistent signal — **all 44/44 valid trials have Reward = 0.0**,
with no trial slipping through to reward > 0 (although the average p2p of 47% shows the model does not
break all the old code, it just never fixes the target bug — f2p is only 12.41%). Compared
with the glm5.2 baseline (31.25%) and glm5.3 (70.31%), this is the largest gap across all
8 benchmarks. The 18 tasks blocked by the gateway keyword filter could not be rerun (a recurring
gateway error, not a transient disk/mirror issue) — the expectation is that the result would not change much if
rerun, based on the trend of 44/44 = 0%.

## GPQA Diamond

Graduate-level science questions (physics/chemistry/biology), designed so they cannot be answered by Googling
— measures deep scientific reasoning.

**Subset:** full **198/198 questions** (gpqa_diamond = the whole dataset, no subsampling), 5-shot CoT.

| Metric | Result |
|---|---|
| Accuracy (flexible-extract) | **52.53%** |
| MAX_GEN_TOKENS | 65536 |
| CCU | 4 |
| Wall clock | ~155.65s (~2.6 minutes) |

**Note:** the `exact_match,strict-match` column (0.0%) is the familiar extraction-bug artifact of
lm-eval on models with long CoT — use `flexible-extract` as the main number. Compared with the
glm5.2 baseline (84.34%) and glm5.3 (87.88%), it is much lower (**-32 points** vs glm5.2) but the
gap is still much smaller than on the 2 agentic benchmarks above — showing the model still retains
some single-turn reasoning/knowledge ability, and is truly weak only on multi-step tasks.

## MMLU-Pro

Multi-domain knowledge + reasoning (14 subjects), with harder distractors than the original MMLU.

**Subset:** 36 questions/subject × 14 subjects = **504/12,032 questions** (the whole MMLU-Pro test
split), same as both baselines.

| Metric | Result |
|---|---|
| Overall | **83.13%** (lm-eval weighted aggregate, ~419/504) |
| Weakest | history 61.11%, other 63.89%, health 69.44% |
| MAX_GEN_TOKENS | 65536 |
| CCU | 4 |
| Wall clock | ~37.4s |

**Note:** compared with the glm5.2 baseline (84.33%) and glm5.3 (85.32%), only ~1-2 points lower —
almost equivalent, completely different from the sharp drop on GPQA/SWE-bench
Pro/DeepSWE. Same "weakest" pattern in history/other as both baselines.

## LiveCodeBench

Generating code for new programming-contest problems (after the data cutoff date), reducing the risk that the model memorized
the solutions.

**Subset:** codegeneration scenario, **198/1,055 problems** (`release_latest` has 1,055
problems in total) — close to both baselines (glm5.2 used 199, glm5.3 used 200).

| Metric | Result |
|---|---|
| Raw Pass@1 (denominator 198) | 93.94% (186/198) |
| Pass@1 after fixing the grading bug (see note) | **98.48%** (195/198) |
| Raw breakdown by difficulty | easy 90.9% (60/66), medium 93.8% (91/97), hard **100%** (35/35) ⚠️ |
| MAX_GEN_TOKENS | *(not confirmed in this verification)* |
| CCU | *(not confirmed)* |

**⚠️ Note — contamination suspicion, similar to the glm5.3 warning, even clearer:**
- The race-condition grading bug was verified and fixed (see
  [[lcb-grading-race-condition-bug]]): 12 problems were initially graded as failed; rerunning the real code
  against the real test cases showed 9/12 (75%) actually pass everything → the correct number is 195/198 = 98.48%, not
  93.94%.
- **Hard = 100% (35/35) even in the raw number, before fixing the bug** — while this model
  nearly completely fails on the 2 other agentic benchmarks (SWE-bench Pro 22.5%, DeepSWE 0.0%).
  A model that is severely weak at multi-step code fixing yet scores perfectly on single-turn "hard" programming
  problems is a very strong sign of contamination — the old, fixed LiveCodeBench problem set,
  public for >1 year (2023-2024), with solutions/editorials publicly available.
  **Strong recommendation: do not use 98.48%/93.94% as the final number for this model** — it needs to be rerun
  with a `release_version` newer than gemma-4's training cutoff before publishing.
- Compared with the baselines: glm5.2 60.80%/61.31% (hard only 25.0%), glm5.3 95.5%/98.45% (hard
  97.1%, also already flagged for contamination). Gemma4 hard=100% is the highest of the 3 runs,
  further reinforcing the suspicion that the problem lies in the LiveCodeBench problem set having its solutions exposed, not
  specific to any one vendor.

## SciCode

Generating code for multi-step scientific computing problems, graded right/wrong by numeric results.

**Subset:** "without_background" split, **30/65 problems** (the full test split has 65 problems, not
counting 15 validation problems) — same as both baselines. There was 1 half-broken run log
(2026-09-14, `status="started"`, 0 samples) before the final log used here (2026-09-15,
`status="success"`, 30/30 samples).

| Metric | Result |
|---|---|
| Sub-steps correct | **41.23%** (47/114) |
| Whole problem correct (all sub-steps) | **13.33%** (4/30) |
| Total tokens | 326,814 (168,600 input + 99,334 output, 58,880 input cached) |
| CCU | 4 (`max_connections`) |
| Wall clock | **~37m48s** (06:08:10 → 06:45:58, 15/09) |
| MAX_GEN_TOKENS | 65536 |

**Note:** compared with the 2 baselines (both glm5.2 and glm5.3 at 40.35%/6.67%), gemma4-31b-fp8 is slightly
ahead on both metrics (sub-step +0.9 points, problem-level +6.7 points) — surprising because
this is a coding benchmark, where this model is weakest on the other agentic benchmarks. The sample size is small
(n=30), so this difference is within natural fluctuation, and does not support concluding that gemma4 is better
at SciCode specifically.

## HLE (Humanity's Last Exam)

The hardest question set available, designed to defeat even frontier models, spanning many fields.

**Subset:** **250/2,158 text-only questions** (HLE has 2,500 questions in total, 342 with images excluded) —
same as both baselines.

| Grading method | Result |
|---|---|
| Raw string-match (lm-eval default, has an extraction bug) | 10.0% (25/250) |
| **LLM-judge (deepseek-v4-pro, used for reporting)** | **12.4% (31/250)** |

**Judge cross-check:** second judge (qwen3.7-plus) = 33/250 (13.2%), self-judge
gemma-4-31b-it = 33/250 (13.2%). All 3 pairs agree on 248/250 (99.2%), κ ≈ 0.964-0.965 — no
sign of self-grading bias (the self-judge is only 0.8 points higher than the main judge, within the noise
range).

| Metric | Result |
|---|---|
| MAX_GEN_TOKENS | *(not confirmed in this verification)* |
| CCU | *(not confirmed)* |

**Note:** the LLM-judge (deepseek-v4-pro) number is used as the main number, following the method
settled on for both baselines. Compared with the glm5.2 baseline (38.0%±3.1%) and glm5.3 (34.4%), it is clearly
lower (**-25.6 points** vs glm5.2) — the same direction of weakness as GPQA, but not a complete
collapse like SWE-bench Pro/DeepSWE.

## BFCL v4 (function calling)

The ability to call functions/tools with correct syntax at the right time, given a list of available functions.

**Subset:** single-turn only (multi-turn/agentic not run, same as both baselines), all
**13/13 categories** = **3,641/4,706 test cases** across all of BFCL v4 (the rest: multi-turn
800 + memory 155 + web_search 100 + format_sensitivity 10, not run).

| Category | Accuracy |
|---|---|
| Non-Live Overall (AST) | **87.96%** |
| — simple (macro-avg Python/Java/JS) | 77.33% (Python 96.00% [384/400], JS 76.00% [38/50], Java 60.00% [60/100]) |
| — multiple | 95.00% |
| — parallel | 92.00% |
| — parallel-multiple | 87.50% |
| — irrelevance detection | 80.83% |
| Live Overall (AST, weighted) | **81.57%** |
| — simple | 84.11% |
| — multiple | 80.91% |
| — parallel | 87.50% |
| — parallel-multiple | 79.17% |
| — relevance detection | 93.75% |
| — irrelevance detection | 75.23% |
| CCU | *(could not be determined — no NUM_THREADS config in the output)* |
| Wall clock | *(could not be determined — all result mtimes fall within 1 second, reflecting only the grading/merge time, not the real answer generation time)* |

**Note:** multi-turn/agentic not run — the aggregate "Overall Acc" column (24.76%) is **unusable**,
see [[bfcl-overall-acc-pitfall]]. Compared with the glm5.2 baseline (Non-Live 88.69%, Live
81.94%) and glm5.3 (Non-Live 88.60%, Live 80.16%), gemma4-31b-fp8 is almost equivalent
(difference <1 point on both metrics) — this is the only benchmark besides SciCode where this model is not
behind the baselines at all, reinforcing the conclusion that gemma4 is only truly weak on **multi-step**
(agentic) tasks, not on single-turn function calling or general knowledge.

## Summary

| Benchmark | gemma4-31b-fp8 | glm5.2-selfhost-extended | glm5.3-w4afp8 |
|---|---|---|---|
| SWE-bench Pro (Pass@1) | **22.5%** | 54.50% | 66.5% |
| DeepSWE (Reward) | **0.0%** | 31.25% | 70.31% |
| GPQA Diamond | **52.53%** | 84.34% | 87.88% |
| MMLU-Pro | **83.13%** | 84.33% | 85.32% |
| LiveCodeBench (⚠️ contamination suspected in all 3 runs) | **98.48%** (raw 93.94%) | 61.31% (raw 60.80%) | 98.45% (raw 97.42%) |
| SciCode (sub-step / problem) | **41.23% / 13.33%** | 40.35% / 6.67% | 40.35% / 6.67% |
| HLE (LLM-judge) | **12.4%** | 38.0% | 34.4% |
| BFCL (Non-Live / Live AST) | **87.96% / 81.57%** | 88.69% / 81.94% | 88.60% / 80.16% |

**Main conclusion:** gemma4-31b-fp8 nearly completely fails on the 2 benchmarks measuring
multi-step agentic/coding ability on real codebases (SWE-bench Pro, DeepSWE), while on
single-turn knowledge/QA/function-calling benchmarks (MMLU-Pro, BFCL, SciCode) it is equivalent
or only slightly lower than the 2 glm baselines. GPQA and HLE sit in the middle — clearly lower
but not collapsed. LiveCodeBench shows a strong contamination signal in all 3 runs (especially
gemma4 reaching 100% raw on hard problems); the LCB number from any of these 3 runs should not be used
as a final number without a rerun on a problem set newer than the training cutoff.
