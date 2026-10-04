# HLE (Humanity's Last Exam)

Reasoning QA, run through lm-eval (`.venv-lmeval`) with the task definitions in
[`tasks/`](tasks/). Files in this directory:

| File | Purpose |
|---|---|
| `run.sh` | Generate answers, print the string-match table, then run the judges |
| `judge.sh` / `judge.py` | Re-grade cached responses with an LLM judge (verdicts cached in sqlite) |
| `rescore.sh` | Re-score an existing run offline |
| `compare_judges.py` | Per-judge scores, pairwise agreement, Cohen's kappa |
| `tasks/` | lm-eval task YAMLs (`hle_exact_match`, `hle_multiple_choice`) |

Judge env vars (`HLE_MAIN_JUDGE`, `HLE_SECOND_JUDGE`, `HLE_SELF_JUDGE`,
`HLE_JUDGE_BASE_URL`, `HLE_JUDGE_API_KEY`) are documented in the
[root README](../../README.md#configuration).

## Grading

`benchmarks/hle/run.sh` generates answers, prints lm-eval's string-match table, and
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

`benchmarks/hle/compare_judges.py` then prints each judge's score plus pairwise
agreement and Cohen's kappa, and writes `judges_comparison.json`. Scores are
shown twice: over all docs a judge graded, and over the docs *every* judge
graded — judges differ in how many verdicts they fail to parse, so the common
set is the only fair basis for comparing them.

```bash
RUN_ID=my-run ./benchmarks/hle/run.sh                    # generate + 3 judges + comparison
HLE_SELF_JUDGE=0 RUN_ID=my-run ./benchmarks/hle/run.sh   # skip the self-judge pass
HLE_SECOND_JUDGE= RUN_ID=my-run ./benchmarks/hle/run.sh  # one judge only
SKIP_JUDGE=1 RUN_ID=my-run ./benchmarks/hle/run.sh       # generate only (floor, do not report)
RUN_ID=my-run SRC_SUBDIR=hle ./benchmarks/hle/judge.sh   # judge an existing run
```

Judge verdicts are cached in sqlite, so re-scoring an already-judged run is free
(`OFFLINE=1` scores from cache with no network). Note the self-judge pass is the
slow one: on the extended glm-5.2 run it took 875s against deepseek's 307s, and
left 7/250 verdicts unparseable because the model kept trying to solve the
question instead of grading it.

See [`docs/BENCHMARK_TIMES.md`](../../docs/BENCHMARK_TIMES.md) for run-time estimates and subset commands.
