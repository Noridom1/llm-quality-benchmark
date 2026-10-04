# Benchmark results — glm5.3-w4afp8

Model: `z-ai/glm-5.3` self-host, **W4A-FP8** quantized. Run date: 2026-09-11/13.
Configuration matches the baseline `glm5.2-selfhost-extended`: `max_gen_toks`/`max_tokens` =
**65536** for all 8 benchmarks (re-verified against each result file below,
not just trusting the environment variable at launch).

**Compared with:** [glm5.2-selfhost-extended](../glm5.2-selfhost-extended/README.md) (baseline, the
unquantized model).

## SWE-bench Pro

Fixing real bugs/features in real codebases (agentic coding, multi-step, graded by running real tests).

**Subset:** full 200/731 instances (SWE-bench Pro has 731 instances in total; these
are the first 200 by index, `LIMIT`/slice `0:200`, identical to the baseline).

90/200 instances crashed from Docker infrastructure (out of disk) on the first run; exactly those 90
instances were rerun (`MAX_GEN_TOKENS=65536`, `WORKERS=12`, `EVAL_WORKERS=12`)
in tmux `swebench-rerun` — **all 200/200 have now finished**, and the numbers below
are read from `eval/eval_results.json` (true/false as per
[[swebench-pro-metric-pitfalls]], not using the progress-bar Accuracy).

| Metric | Result |
|---|---|
| Pass@1 | **133/200 = 66.5%** |
| Avg turns/instance | **72.34** (baseline 59.01) — 1 turn = 1 model call that generates an action, counted from `api_calls`/the number of `role=="assistant"` messages in `.traj.json`, matching 100% across all 400 trajectories (2 jobs) |
| Total tokens | **~612.1M** (608.0M prompt + 4.1M completion), 14,468 API calls (computed from `usage` in each `.traj.json`, not using the `reasoning_tokens` field — see the baseline note) |
| CCU | 12 (agent) / 12 (eval) |
| Wall clock | *(no clean number — this job had a Docker crash phase + rerun interleaved, not a single continuous run like the baseline; first log 2026-09-11 11:43, last eval written 2026-09-13 14:41, but there was downtime in between waiting for the crash to be handled, so it is not used as the real wall clock)* |

**Note:** 7/200 have no real patch (`model_patch` has no valid diff) —
counted as failures per the protocol, not excluded, the same way as in the baseline
(4/200 without a patch). Compared with the baseline (109/200 = 54.50%), this quantized model is
considerably higher (**133/200 = 66.5%**, +12 points), the same upward direction as
DeepSWE below.

## DeepSWE

Similar to SWE-bench Pro but with synthetic tasks (datacurve), graded by the rate of fail→pass (f2p) and pass→pass (p2p) tests in a Docker sandbox.

**Subset:** full **64/113 tasks** (DeepSWE has 113 tasks in total; the 64 tasks are
a random subset with a fixed seed, same as the baseline), merged from 3 batches run sequentially:
- `64tasks-ccu8` (64 tasks, CCU 8) — 43 tasks clean, 21 tasks with infrastructure errors.
- `deepswe_failed_tasks-ccu8` (35 rerun tasks, CCU 8) — re-covers the failed tasks above.
- `rerun6-ccu8` (6 rerun tasks, CCU 8) — supplementary rerun of the 6 tasks still missing.

Merged into `jobs/glm5.3-w4afp8/deepswe/64tasks-merged/MERGE_SUMMARY.json`;
the numbers below are computed directly from the 64 task-level `result.json` files following the
`per_task` mapping in the summary (each task counted exactly once, preferring the clean rerun).

| Metric | Result |
|---|---|
| Reward (task fully passed) | **45/64 = 70.31%** |
| Avg turns/task | **137.81** (baseline 126.27) — counted from the number of `role=="assistant"` messages in each task's `mini-swe-agent.trajectory.json`, matching the `n_agent_steps` field in `result.json` 100% |
| f2p (fail→pass) | **97.68%** (3,281/3,359) |
| p2p (pass→pass, did not break old tests) | **99.996%** (194,096/194,104) |
| Total tokens (64 tasks) | **~1,022.0M** (1,016.1M input, of which 1,010.4M cached + 5.88M output) |
| CCU | 8 (all 3 batches) |
| Wall clock | **~8h32m** (cumulative total of 3 batches run sequentially: 3h49m41s + 43m53s + 3h58m48s) |
| MAX_GEN_TOKENS | 65536 (matches baseline) |

**Note:** compared with the baseline (31.25%/92.86%/99.96%), this quantized model is clearly higher
on all 3 metrics. The first batch `64tasks-ccu8` had 21/64 infrastructure errors (not because the model
is weak), which were rerun clean through the 2 later batches and substituted into the total exactly, not double
counted.

## GPQA Diamond

Graduate-level science questions (physics/chemistry/biology), designed so they cannot be answered by Googling — measures deep scientific reasoning.

**Subset:** full **198/198 questions** (gpqa_diamond = the whole dataset, no
subsampling), 5-shot CoT.

| Metric | Result |
|---|---|
| Accuracy (flexible-extract) | **87.88%** |
| MAX_GEN_TOKENS | 65536 (matches baseline) |
| CCU | *(not confirmed — assumed same as baseline: 8)* |
| Wall clock | *(not measured precisely)* |

**Note:** same harness (lm-eval), which does not log token usage for this backend. The
`exact_match,strict-match` column (4.5%) is the familiar extraction-bug artifact of
lm-eval on models with long CoT — use `flexible-extract` as the main number, same as how the
baseline is read.

## MMLU-Pro

Multi-domain knowledge + reasoning (14 subjects), with harder distractors than the original MMLU.

**Subset:** 36 questions/subject × 14 subjects = **504/12,032 questions** (the whole
MMLU-Pro test split), same as the baseline.

| Metric | Result |
|---|---|
| Overall | **85.32%** (430/504) |
| Weakest | history 63.9%, other 66.7%, health 75.0% |
| MAX_GEN_TOKENS | 65536 (matches baseline) |
| CCU | *(not confirmed — assumed same as baseline: 8)* |
| Wall clock | *(not measured precisely)* |

**Note:** this result (mtime 2026-09-13) is the most recent rerun after
adjusting MAX_GEN_TOKENS=65536 to match the baseline — do not use any earlier run from
09-11 if present.

## LiveCodeBench

Generating code for new programming-contest problems (after the data cutoff date), reducing the risk that the model memorized the solutions.

**Subset:** codegeneration scenario, **200/1,055 problems** (`release_latest` has
1,055 problems in total; the first 200 in dataset order), the same 200 problems as the baseline
(194/200 evaluable, baseline 199/200).

| Metric | Result |
|---|---|
| Pass@1 (denominator 194, re-verified by running real code) | **98.45%** (191/194) ⚠️ see note |
| Pass@1 (full denominator 200, counting the 6 eval-crashed problems as failures) | **95.5%** (191/200) ⚠️ see note |
| MAX_GEN_TOKENS | 65536 (matches baseline) |
| CCU | 4 (script default, no override found) |
| Wall clock | *(not measured precisely)* |

**⚠️ Note — carefully verified, this number is real (not a bug/stale cache) but is still
suspicious and should not yet be published as the final number:**
- **Technical causes ruled out:** comparing each `question_id` between the 2 jobs confirmed
  exactly 100% the same 200 problems (same contest_date 2023-05→2024-07, same
  `release_latest`); the generated code differs on every problem (different hashes, no
  shared symlink/cache) — these are genuinely 2 independent generations.
- **Bug #1 in grading — lost denominator:** when evaluating a problem crashes, the harness
  records no result and the problem disappears from the denominator instead of counting as a failure — glm5.3
  lost 6/200 problems this way (5 had valid code yet still crashed during grading, 1
  failed to generate code), the baseline only lost 1/200 (no code generated). This
  applies to both runs, affecting glm5.3 more (6 problems vs 1).
- **Bug #2 in grading — wrong test cases assigned (newly found 2026-09-15):**
  a race condition during parallel grading with `ProcessPoolExecutor` caused some
  problems to be assigned the test cases of **another problem** and then graded "Wrong Answer"/"Runtime
  Error" even though the code is 100% correct (evidence: the `metadata` field of the failed problem contains
  the input/expected of a completely different problem). Verified by rerunning
  `code_list[0]` of every `pass@1=0` problem (194 evaluated) against the real
  public+private test cases loaded from `load_code_generation_dataset`: of the 5
  problems graded as failed, **2** (`minimum-number-of-coins-for-fruits`,
  `apply-operations-to-make-sum-of-array-greater-than-or-equal-to-k`) pass
  all the real tests. Bug details + verification method: see memory
  `lcb-grading-race-condition-bug.md`.
- **Correctly recomputed, with both bug fixes combined:** within the denominator of 194 (evaluated),
  Pass@1 = **191/194 = 98.45%**. Converted to the full denominator of 200 (keeping the
  "6 lost-denominator problems = fail" treatment from bug #1; those 6 were not re-verified separately because
  the exact 6 `question_id`s could not be re-identified — diffing by dataset order
  gives 13 different problems, which does not match; the original subset selection needs to be investigated
  before touching this number):
  Pass@1 = **191/200 = 95.5%**; the baseline (glm5.2) re-verified in the same
  way = **122/199 ≈ 61.3%** (see the glm5.2-selfhost-extended README).
- **Breakdown by `question_id`** (not updated after bug #2; the numbers below
  still follow the bug #1 fix — easy/medium/hard shift slightly if the 2 just-reclassified
  problems are counted): easy 98.4% (63/64), medium **96.8%** (92/95), hard **97.1%**
  (34/35) — baseline: easy 95.5%, medium 50.5%, hard 25.0%.
- **Contamination suspicion remains:** near-saturation (~98%) even on `hard`
  problems is an abnormal jump between 2 self-host versions of the same model family, on
  the same old, fixed LiveCodeBench problem set, public for over 1 year (2023-2024) — if
  glm5.3 has a later training cutoff than glm5.2, the solutions to these problems (which have
  public editorials/GitHub) very likely leaked into the training data.
  Recommendation: rerun with a `release_version` newer than glm5.3's training
  cutoff before putting the 95.5%/98.45% numbers into the official report.

## SciCode

Generating code for multi-step scientific computing problems, graded right/wrong by numeric results.

**Subset:** "without_background" split, **30/65 problems** (the full test split has
65 problems, not counting 15 validation problems) / multiple sub-steps — same as the baseline.

| Metric | Result |
|---|---|
| Sub-steps correct | **40.35%** (46/114) |
| Whole problem correct (all sub-steps) | **6.67%** (2/30) |
| Total tokens | **1,767,922** (117,214 input + 1,551,700 output, 99,008 input cached) |
| CCU | 4 (script default `MAX_CONNECTIONS`, no override found) |
| Wall clock | **1h37m** (18:28:28 → 20:05:28, 11/09) |
| MAX_GEN_TOKENS | *(not confirmed numerically in the log — script default 16384 if not overridden)* |

**Note — verified, this is a genuine coincidence, not a bug:** reading the
`.eval` log directly (`inspect_ai.log.read_eval_log`) and comparing **each problem**
between the 2 runs, 13/30 problems have different sub-step results (e.g. problem 14: glm5.3 correct
on 2/2 steps, glm5.2 only 1/2; problem 72: 7/9 vs 5/9; problem 26: 3/3 vs 2/3...) — the two runs are
fully independent, with different generated code in every file. The totals of correct sub-steps
across all 30 problems just happen to be equal (46/114 on both sides) due to offsetting
(some problems 5.3 is better, others 5.2 is better) — a natural consequence of n=30 being too small,
not a sign of error. Treat this figure as trustworthy.

## HLE (Humanity's Last Exam)

The hardest question set available, designed to defeat even frontier models, spanning many fields.

**Subset:** **250/2,158 text-only questions** (HLE has 2,500 questions in total, of which 342
with images were excluded, leaving 2,158 eligible text-only questions; took the first 125
exact-match + 125 multiple-choice) — same as the baseline.

| Grading method | Result |
|---|---|
| Raw string-match (lm-eval default, has an extraction bug) | 25.6% (exact_match flexible-extract) |
| **LLM-judge (deepseek-v4-pro, used for reporting)** | **34.4% (86/250)** |

**Judge cross-check:** second judge (qwen3.7-plus) = 87/250 (34.8%), κ vs
deepseek = 0.973 (242/245 agree, 245 questions in common). Self-judge glm-5.2 = 87/245
graded, κ vs deepseek = 0.991 (244/245 agree) — no sign of self-grading
bias.

**CCU / wall clock:**
- Answer generation (generate): wall clock ~5h59m (18:41 → 00:40, 11-12/09).
- Judge grading (deepseek-v4-pro, 250 docs): wall clock ~6.0 minutes (357.6s).

| Metric | Result |
|---|---|
| MAX_GEN_TOKENS | 65536 (matches baseline) |
| CCU | *(not confirmed — assumed same as baseline: 6)* |

**Note:** the LLM-judge number is used as the main number, following the method settled on in the
baseline (see [[glm5.2-extended-other-benchmarks]]). Compared with the baseline
38.0%±3.1%, this number (34.4%) is lower — within a reasonable fluctuation range for
n=250, with no anomaly like the LiveCodeBench/SciCode ones above.

## BFCL v4 (function calling)

The ability to call functions/tools with correct syntax at the right time, given a list of available functions.

**Subset:** single-turn only (multi-turn/agentic not run, same as the baseline),
all **13/13 categories** = **3,641/4,706 test cases** across all of BFCL v4 (the
rest: multi-turn 800 + memory 155 + web_search 100 + format_sensitivity 10,
not run).

| Category | Accuracy |
|---|---|
| Non-Live Overall (AST) | **88.60%** |
| — simple (macro-avg Python/Java/JS) | 77.92% (Python 95.75% [383/400], JS 76.00% [38/50], Java 62.00% [62/100]) |
| — multiple | 95.50% (191/200) |
| — parallel | 92.00% (184/200) |
| — parallel-multiple | 89.00% (178/200) |
| — irrelevance detection | 69.58% (167/240) |
| Live Overall (AST, weighted) | **80.16%** |
| — simple | 83.72% (216/258) |
| — multiple | 79.49% (837/1053) |
| — parallel | 81.25% (13/16) |
| — parallel-multiple | 70.83% (17/24) |
| — relevance detection | 81.25% (13/16) |
| — irrelevance detection | 70.81% (626/884) |
| CCU | 4 (script default `NUM_THREADS`, no override found) |
| Wall clock | **~1h16m** (10:26:45 → 11:42:52, 11/09) |

**Note:** multi-turn/agentic not run — the aggregate "Overall Acc" column (23.90%)
is **unusable**, see [[bfcl-overall-acc-pitfall]]. Compared with the baseline
(Non-Live 88.69%, Live 81.94%), the numbers here are almost equivalent (difference
<2 points) — no sign of anything abnormal.
