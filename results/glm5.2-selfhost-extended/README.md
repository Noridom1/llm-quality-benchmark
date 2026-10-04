# Benchmark results — glm5.2-selfhost-extended

Model: `z-ai/glm-5.2` (self-host). Run date: 2026-09-09/10.

## SWE-bench Pro

Fixing real bugs/features in real codebases (agentic coding, multi-step, graded by running real tests).

**Subset:** full 200/731 instances (SWE-bench Pro has 731 instances in total; these
are the first 200 by index).

| Metric | Result |
|---|---|
| Pass@1 | **109/200 = 54.50%** |
| Avg turns/instance | **59.01** (vs. glm5.3-w4afp8: 72.34) — 1 turn = 1 model call that generates an action, counted from `api_calls`/the number of `role=="assistant"` messages in `.traj.json` |
| Total tokens | **~1.024 billion** (1,022.4M prompt + 1.85M completion), 11,802 API calls |
| CCU | 4 (agent) / 4 (eval) |
| Wall clock | **~11h36m** (07:48 → 19:23, 09/09) |

**Note:** 4/200 have no real patch (3 cases where the model submitted `git diff --cached --stat` instead of the real diff, 1 case that exhausted its step budget) — counted as failures per the protocol, not excluded. 0 instances with infrastructure (Docker) errors. The `reasoning_tokens` field in the self-host endpoint's usage is unreliable (many calls report reasoning > completion) — only use the total prompt/completion.

## DeepSWE

Similar to SWE-bench Pro but with synthetic tasks (datacurve), graded by the rate of fail→pass (f2p) and pass→pass (p2p) tests in a Docker sandbox.

**Subset:** full **64/113 tasks** (DeepSWE has 113 tasks in total; the 64 tasks are
a random subset with a fixed seed), merged from 3 clean batches (no errors):
- `32tasks-ccu8` (32 tasks, CCU 8) — finished clean from the start.
- `tasks33-64-ccu16` (32 tasks, CCU 16) — 22 tasks ran clean, 10 tasks hit infrastructure errors (Docker network pool exhausted at CCU16).
- `rerun10-ccu8` (10 tasks, CCU 8) — reran exactly the 10 failed tasks above, finished clean.

Manually merged into `jobs/glm5.2-selfhost-extended/deepswe/64tasks-merged/` (symlinks to the 64 original task dirs + `MERGE_SUMMARY.json`). The numbers below are computed directly from the 64 task-level `result.json` files (the most accurate source, not going through batch-level histograms).

| Metric | Result |
|---|---|
| Reward (task fully passed) | **20/64 = 31.25%** |
| Avg turns/task | **126.27** (vs. glm5.3-w4afp8: 137.81) — counted from the number of `role=="assistant"` messages in each task's trajectory, matching the `n_agent_steps` field in `result.json` 100% |
| f2p (fail→pass) | **92.86%** (3,119/3,359) |
| p2p (pass→pass, did not break old tests) | **99.96%** (194,029/194,104) |
| partial (average) | 93.27% |
| Total tokens (64 tasks) | **~756.0M** (751.1M prompt, of which 744.8M cached + 4.91M completion) |
| CCU | 8 (2 batches) / 16 (1 batch, see note) |
| Wall clock | **~5h30m** (cumulative total of 3 batches run sequentially, not concurrently: 2h47m + 1h39m + 1h5m) |

**Note:** CCU 16 caused 10/32 trials to fail because the Docker network pool ran out (not because the model is weak) — those 10 tasks were rerun clean at CCU8 and substituted into the total, not double counted. The 2 older batches (`64tasks-ccu12`, `100tasks-ccu16`) are earlier attempts that hit many infrastructure errors (container/network) before the CCU8/16 configuration above was settled — not used for reporting, kept as-is in the job directory as logs.

## GPQA Diamond

Graduate-level science questions (physics/chemistry/biology), designed so they cannot be answered by Googling — measures deep scientific reasoning.

**Subset:** full **198/198 questions** (gpqa_diamond = the whole dataset, no
subsampling), 5-shot CoT.

| Metric | Result |
|---|---|
| Accuracy | **84.34%** |
| CCU | 8 |
| Wall clock | **57.9 minutes** |

**Note:** the harness (lm-eval) does not log token usage for this backend — there is no token count.

## MMLU-Pro

Multi-domain knowledge + reasoning (14 subjects), with harder distractors than the original MMLU.

**Subset:** 36 questions/subject × 14 subjects = **504/12,032 questions** (the whole
MMLU-Pro test split), due to cost limits.

| Metric | Result |
|---|---|
| Overall | **84.33%** |
| Weakest | history 55.6%, other 66.7%, law 72.2% |
| CCU | 8 |
| Wall clock | **37.4 minutes** |

**Note:** subsampled numbers, not fully representative of each subject (36 questions/subject is a small sample). Same harness as GPQA, also no token logging.

## LiveCodeBench

Generating code for new programming-contest problems (after the data cutoff date), reducing the risk that the model memorized the solutions.

**Subset:** codegeneration scenario, **199/1,055 problems** (`release_latest` has
1,055 problems in total), pass@1 (n=1, temperature 0).

| Metric | Result |
|---|---|
| Pass@1 (as reported by the harness) | 60.80% (121/199) |
| Pass@1 (re-verified by running real code, see note) | **61.31%** (122/199) |
| CCU | 4 (script default, no override found) |
| Wall clock | not logged — only the end time ~06:54 09/09 exists, no reliable start time |

**Note:** the harness cache only stores prompt/response text, with no token usage.

**⚠️ Note — re-verified 2026-09-15 (during the same investigation of the
glm5.3 grading bug, see `jobs/glm5.3-w4afp8/README.md` and memory
`lcb-grading-race-condition-bug.md`):**
- Among the 78/199 problems graded as failed, I reran `code_list[0]` myself against the real
  public+private test cases (loaded from `load_code_generation_dataset`):
  only **1 problem** (`apply-operations-to-make-sum-of-array-greater-than-or-equal-to-k`)
  was hit by the grading bug (assigned another problem's test cases — a race condition
  during parallel grading); its code actually passes everything. **77/78 of the rest genuinely fail.**
- Of the 77 genuine failures, **74 have a completely empty `code_list`** (the model
  failed to generate code) — not because the WAF blocked the keyword "123" (checked,
  0/74 problem statements contain the string "123"); most likely a timeout/running out of
  token budget during long reasoning. Heavily skewed toward hard problems: **26/36
  hard (72%) and 45/97 medium (46%)** are empty, while easy is only 3/66
  (4.5%). So most of the gap vs. glm5.3/gemma4 on LiveCodeBench comes from
  **failing to generate code for hard problems**, not necessarily from wrong logic —
  the exact technical cause is not confirmed (no log/config was found
  recording the MAX_GEN_TOKENS or client_timeout actually used for this LCB run).
- Only 4/78 failed problems have real code to grade, of which 3 are genuine logic errors
  (`count-of-integers`, `sum-of-imbalance-numbers-of-all-subarrays` 10/14,
  `remove-adjacent-almost-equal-characters` 14/15).
- Recomputed: Pass@1 = **122/199 = 61.31%** (almost unchanged from the original report,
  since the grading bug only affected 1/78 — very different from glm5.3/gemma4, where this bug affected
  40-75% of failures).

## SciCode

Generating code for multi-step scientific computing problems, graded right/wrong by numeric results.

**Subset:** "without_background" split (no background knowledge given, harder),
**30/65 problems** (the full test split has 65 problems, not counting 15 validation problems) /
multiple sub-steps.

| Metric | Result |
|---|---|
| Sub-steps correct | 40.35% |
| Whole problem correct (all sub-steps) | **6.67%** |
| Total tokens | **1,359,525** (106,980 input + 1,189,057 output, with 63,488 input tokens cached) |
| CCU | 8 |
| Wall clock | **1h58m** (07:14:23 → 09:12:04, 09/09) |

**Note:** the large gap between the 2 numbers shows the model gets individual small steps right but rarely gets a whole multi-step problem fully right.

## HLE (Humanity's Last Exam)

The hardest question set available, designed to defeat even frontier models, spanning many fields.

**Subset:** **250/2,158 text-only questions** (HLE has 2,500 questions in total, of which 342
with images were excluded, leaving 2,158 eligible text-only questions; took the first 125
exact-match + 125 multiple-choice).

| Grading method | Result |
|---|---|
| Raw string-match (lm-eval default) | 13.6% (has an extraction bug, discarded) |
| String-match with the bug fixed | 32.4% (81/250) |
| **LLM-judge (deepseek-v4-pro)** | **38.0% ± 3.1% (95/250)** |

**CCU / wall clock:**
- Answer generation (generate, shared by all 3 grading methods): CCU 6, wall clock **4h49m** (17,345s).
- Judge grading (deepseek-v4-pro, 250 docs): CCU 6, wall clock **~5.1 minutes** (307s).

**Note:** the LLM-judge number is used as the main number because upstream standard HLE is graded by a judge, not by string matching. Verified to be unbiased: a second independent judge (qwen3.7-plus) agrees on 249/250; self-grading with glm-5.2 agrees with qwen on 243/243 — no sign of the model favoring itself. There is no token count (neither answer generation nor judge grading logs usage; the judge only logs character length).

## BFCL v4 (function calling)

The ability to call functions/tools with correct syntax at the right time, given a list of available functions.

**Subset:** single-turn only by design (multi-turn and agentic
web_search/memory not run) — but ran **all 13/13 single-turn
categories** (7 non-live + 6 live) = **3,641/4,706 test cases** across all of BFCL
v4 (the rest: multi-turn 800 + memory 155 + web_search 100 +
format_sensitivity 10, not run), unlike the previous run which only had 5 categories
(since replaced). Source: `jobs/glm5.2-singleturn/bfcl/`.

| Category | Accuracy |
|---|---|
| Non-Live Overall (AST) | **88.69%** |
| — simple (macro-avg Python/Java/JS) | 77.25% (Python 95.75%, JS 74.00%, Java 62.00%) |
| — multiple | 95.00% (190/200) |
| — parallel | 93.50% (187/200) |
| — parallel-multiple | 89.00% (178/200) |
| — irrelevance detection | 78.75% (189/240) |
| Live Overall (AST, weighted) | **81.94%** |
| — simple | 90.70% (234/258) |
| — multiple | 80.06% (843/1053) |
| — parallel | 75.00% (12/16) |
| — parallel-multiple | 75.00% (18/24) |
| — relevance detection | 81.25% (13/16) |
| — irrelevance detection | 76.70% (678/884) |
| CCU | 4 (script default `NUM_THREADS`, no override found) |
| Wall clock | **~36m36s** (08:27:19 → 09:03:55, 09/09, measured from the creation time of the `result/` directory → the time the last result file was written) |

**Note:** multi-turn and agentic (web_search/memory) were not run — by design, only single-turn is measured. So the aggregate "Overall Acc" column in `data_overall.csv` (24.84%) is still **unusable** for an overall report — BFCL counts the unrun multi-turn/agentic as 0% and then aggregates, see [[bfcl-overall-acc-pitfall]]; use the separate Non-Live/Live Overall above. BFCL has `input_token_count`/`output_token_count` fields in the result json but they are all 0 (the harness cannot get usage from this self-host endpoint) — there is no real token count.
