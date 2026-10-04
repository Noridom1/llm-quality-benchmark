# Report notes — RUN_ID=glm5.2-selfhost-extended

## Decision: a failure caused by not following instructions still counts as a failure

Instances that failed because of a "wrong submission format" were not rerun. An
agentic benchmark measures protocol compliance as well as code-fixing ability.
Rerunning only the broken cases and keeping the better result = cherry-picking
favorable samples: the final number would be inflated and not comparable with
other models run on the same harness.

## Cases to mention in the report

### 1. Wrong submission format (3 cases) — the model did not follow instructions

The config `tasks/swebench-pro/swebench_pro.yaml:134` instructs:

    echo COMPLETE_TASK_AND_SUBMIT_FINAL_OUTPUT && git add -A && git diff --cached

The model ran:

    echo COMPLETE_TASK_AND_SUBMIT_FINAL_OUTPUT && git add -A && git diff --cached --stat

`has_finished` (mini-swe-agent `agents/default.py:127`) only checks whether the
first line matches the marker, then accepts everything after it as the patch,
with no validation. So the `--stat` table was written into preds.json in place
of the diff.

| instance | exit_status | api_calls |
|---|---|---|
| instance_gravitational__teleport-c782838c3a174fdff80cafd8cd3b1aa4dae8beb2 | Submitted | 143 |
| instance_flipt-io__flipt-05d7234fa582df632f70a7cd10194d61bd7043b9 | Submitted | 85 |
| instance_protonmail__webclients-6e1873b06df6529a4695... | Submitted | 123 |

From reading the trajectories: in all three, the code was already fixed and the
tests passed. The container runs with `--rm`, so the real diff was lost along
with the container.

**This is a recurring failure mode, not a random one.** All 3 cases have
exit=Submitted with plenty of steps left (85-143 out of a 250 cap) -- the model
believed it was done. It knew which command to run (the marker line and
`git add -A` are both correct) and only added `--stat`. If the report only
gives the total number of failures, this finding is hidden.

### 2. Step budget exhausted (1 case) — a genuine failure

- instance_protonmail__webclients-da91f084c0f532d9cc8ca385a701274d598057b8
  exit_status=LimitsExceeded, api_calls=250/250, empty submission.

## Warnings on reading the numbers

- The "Accuracy" line in the Phase 2 progress bar is NOT reliable: it counts
  instances not yet evaluated and instances with no patch as failures.
  Source of truth: the eval/<uid>/*_output.json files, key `tests` (not `resolved`).
- Do not count errors from preds/minisweagent.log or exit_statuses_*.yaml: these
  two sources accumulate across every launch, and still contain the numbers of
  the earlier cancelled run. Count from preds.json: any entry whose model_patch
  is not a diff is broken.

## Run context

The first run was cancelled because /mnt filled up (200 instances x ~3.7GB image = ~740GB > 492GB disk).
93/200 instances died with docker exit 127. Pruned and reran with a continuous
prune-loop; this run had 0 Docker-caused crashes.

## FINAL RESULT (2026-09-09 19:23)

**Pass@1 = 109/200 = 54.50%**

Independently verified: recomputing from the 200 `eval/<uid>/*_output.json`
files with the harness's own formula `(fail_to_pass | pass_to_pass) <= passed_tests`
gives exactly 109/200, matching `eval_results.json` exactly, with 0 missing
files and 0 mismatched cases.

Side figure: counting only the 196 instances with a real patch gives 109/196 = 55.61%.
**Do not use this figure as the main result** -- see the decision section at the top of the file.
Mention it only to show that the 4 broken cases shift the result by just 1.1 percentage points.

All 4 cases without a patch evaluated to False, as expected.
