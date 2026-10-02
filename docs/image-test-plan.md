# Test Plan: `quality-bench:latest`

The claim under test is that someone with only an endpoint, a model name and
an API key can run any of the 8 benchmarks from this image. Each result must
be real and resumable, and must land under `jobs/<RUN_ID>/<benchmark>/` on
the host. Every test case is written from that user's side: a `docker run`
command and what they should see. Nothing is run from the source checkout.

## Phases

| Phase | Benchmarks | Needs host docker socket | Status |
|---|---|---|---|
| **1** | GPQA, MMLU-Pro, HLE, LiveCodeBench, SciCode, BFCL | no | **run now** |
| 2 | SWE-bench Pro, DeepSWE | yes (sibling containers, same-path jobs mount) | planned, run later |

In Phase 1, "without docker" means without the docker socket. These six
benchmarks still run inside the image, but they never launch sibling
containers. All Phase 1 cases therefore run **without**
`-v /var/run/docker.sock:...`, which also shows that the socket really is
optional for them.

## Risks found while writing this plan (review before running)

| # | Risk | Affects | Expected symptom |
|---|---|---|---|
| R1 | LiveCodeBench looks up `LanguageModelStore[args.model]`, and our patch registers only `z-ai/glm-5.2` and `google/gemma-4-31b-it`. | LCB | `KeyError: '<model>'` for any other `MODEL_NAME`. **Fixed:** `patches/livecodebench/0002` registers `LCB_MODEL` (exported by `run_livecodebench.sh`) at import |
| R2 | BFCL model keys are hardcoded in `model_config.py`: `z-ai/glm-5.2-FC`, `google/gemma-4-31b-it-{FC,PROMPT}`, and so on. | BFCL | "unknown model" error for any other `MODEL_NAME`. **Fixed:** `patches/bfcl/0002` registers `<BFCL_MODEL>-FC`/`-PROMPT` (exported by `run_bfcl.sh`) at import |
| R3 | The HLE judges (`deepseek/deepseek-v4-pro`, `qwen/qwen3.7-plus`) must be served somewhere. A self-hosted endpoint that serves one model has no judge. **Mitigated:** `HLE_JUDGE_BASE_URL`/`HLE_JUDGE_API_KEY` point the judges at another endpoint. | HLE | Without a reachable judge: generation succeeds, judge requests fail, the run exits 1 with "score is incomplete" |
| R4 | `MAX_GEN_TOKENS` now defaults to 65536. An endpoint with `max_model_len` ≤ 65536 + prompt rejects every request. | all | HTTP 400 "maximum context length ..." on the first request |
| R5 | GPQA is gated on HF. | GPQA | Dataset 401/403 without `HF_TOKEN` |

R1 and R2 break "any model name". TC-11 and TC-12 cover them. They are
expected to FAIL on the current image, and either a fix (dynamic
registration) or a documented limitation is needed before we can claim
support for arbitrary models.

## Test environment (the user's inputs)

```bash
export API_KEY=...                            # the key under test
export OPENAI_BASE_URL=http://<host>:<port>/v1
export MODEL_NAME=<served-model-id>           # exactly as /v1/models reports it, no openai/ prefix
export HF_TOKEN=hf_...
export IMG=quality-bench:latest
export RUN_ID=imgtest-$(date +%Y%m%d)-p1      # fresh per test campaign
mkdir -p jobs

# Shared flags (every case below uses these unless stated otherwise)
COMMON=(--rm -it -e API_KEY -e OPENAI_BASE_URL -e MODEL_NAME -e HF_TOKEN -e RUN_ID
        -v "$PWD/jobs:$PWD/jobs" -e JOBS_ROOT="$PWD/jobs")
```

Record the image under test: `docker image inspect $IMG -f '{{.Id}} {{.Created}}'`.

Unless a case says otherwise, a case passes when **all** of these hold:
1. The container exits 0.
2. The result file below exists on the host and holds a numeric score.
3. The logged `Max gen tokens` / `max_gen_toks` equals 65536 (or the override).
4. No sample counts as "scored" when it actually errored: check the
   error/empty-response count in the result.
5. The files are owned by a user the host can read and delete.

## Stage 0: preflight (≈2 min, gate for everything else)

| ID | Case | Command | Expected |
|---|---|---|---|
| TC-01 | Endpoint is reachable and the key works | `curl -s -H "Authorization: Bearer $API_KEY" $OPENAI_BASE_URL/models` | 200; `MODEL_NAME` appears in the list |
| TC-02 | The endpoint's context fits 65k output (R4) | Chat request with `max_tokens: 65536` and a short prompt | 200, no context-length error. If it fails, run the rest of Phase 1 with `-e MAX_GEN_TOKENS=<ctx-4096>` and log it as a deviation |
| TC-03 | Required env missing | `docker run --rm $IMG` (no `-e`) | Exits ≠0 immediately with `API_KEY is required` |
| TC-04 | Bad JOBS_ROOT | `docker run "${COMMON[@]/JOBS_ROOT=*/JOBS_ROOT=/nope}" $IMG scripts/run_gpqa.sh` | Exits 1: `JOBS_ROOT=/nope is not a directory` |
| TC-05 | Secrets never reach disk outside `.env` | After any Phase 1 run: `grep -rl "$API_KEY" jobs/$RUN_ID \| grep -v '/bfcl/.env$'` | No output. BFCL's own `.env` is expected, and nothing else may contain the key |

## Stage 1: smoke, one benchmark at a time (≈30–60 min total)

Each case starts a fresh container with a small `LIMIT`. Run them in order:
they get slower as you go down, so a broken image fails fast.

| ID | Benchmark | Command | Result to check |
|---|---|---|---|
| TC-06 | GPQA | `docker run "${COMMON[@]}" -e LIMIT=4 -e NUM_CONCURRENT=2 $IMG scripts/run_gpqa.sh` | `jobs/$RUN_ID/gpqa/<model__esc>/results_*.json` → `gpqa_diamond_cot_n_shot` has `exact_match` and `n-samples` = 4 |
| TC-07 | MMLU-Pro | `... -e LIMIT=2 -e NUM_CONCURRENT=4 $IMG scripts/run_mmlu_pro.sh` | `jobs/$RUN_ID/mmlu_pro/*/results_*.json`: 14 subjects × 2 = 28 samples, and an aggregate `mmlu_pro` score |
| TC-08 | HLE (generation only) | `... -e LIMIT=3 -e SKIP_JUDGE=1 $IMG scripts/run_hle.sh` | `jobs/$RUN_ID/hle/*/samples_hle_{exact_match,multiple_choice}_*.jsonl`, 3 lines each, with non-empty responses |
| TC-09 | HLE with judge endpoint | `... -e LIMIT=3 -e HLE_JUDGE_BASE_URL -e HLE_JUDGE_API_KEY -e HLE_SELF_JUDGE=0 $IMG scripts/run_hle.sh` | Both default judges run (main + second), each prints `Judge URL: <judge endpoint>`, `jobs/$RUN_ID/hle-judged/` has verdicts for all 6 samples, the comparison table prints, exit 0 |
| TC-09b | HLE, judge unreachable | TC-09 without the two judge vars, on an endpoint that doesn't serve the judges | Exit 1, "score is incomplete", TC-08-style samples still intact under `jobs/$RUN_ID/hle/` |
| TC-10 | LiveCodeBench | `... -e LIMIT=4 -e MULTIPROCESS=2 $IMG scripts/run_livecodebench.sh` | `jobs/$RUN_ID/livecodebench/output/<repr>/Scenario.codegeneration_1_0.0_eval.json` with `pass@1` and 4 problems |
| TC-11 | LCB, unregistered model (R1) | TC-10 with a model **not** in the LCB patch, e.g. `-e MODEL_NAME=qwen/qwen3-32b` on an endpoint that serves it | Same as TC-10: no `KeyError`, `output/<model with / as _>/…_eval.json` has `pass@1` |
| TC-12 | BFCL | `... -e NUM_THREADS=2 -e TEST_CATEGORY=simple_python $IMG scripts/run_bfcl.sh` | `jobs/$RUN_ID/bfcl/score/<key>/…simple_python…_score.json` with accuracy. Read the per-category json, **not** Overall Acc (see `bfcl-overall-acc-pitfall`). Must also pass for an unregistered `MODEL_NAME` (R2) |
| TC-13 | BFCL PROMPT mode | TC-12 plus `-e BFCL_MODE=PROMPT` | Same as TC-12, including for an unregistered `MODEL_NAME` |
| TC-14 | SciCode | `... -e LIMIT=2 -e SPLIT=validation -e MAX_CONNECTIONS=2 $IMG scripts/run_scicode.sh` | `jobs/$RUN_ID/scicode/logs/*.eval` plus a printed sub-problem/main-problem accuracy. Shows the baked-in `test_data.h5` is there (no h5py file-not-found error) |

For each case, also check that the header the script prints shows the
expected `Model`, `Endpoint` and `Max gen tokens: 65536`.

## Stage 2: image-level behaviour (Phase 1 benchmarks only)

| ID | Case | How | Expected |
|---|---|---|---|
| TC-15 | Resume / cache hit | Rerun TC-06 with the identical command | Finishes in seconds, and the lm-eval log shows cached requests (no new endpoint calls) with the same score. Repeat for TC-10 (`--continue_existing`) |
| TC-16 | Resume after a kill | Start TC-07 with `LIMIT=10`, then `docker kill` it midway and rerun | The second run only requests what is missing, and the final sample count is 140 |
| TC-17 | Env override wins | TC-06 plus `-e MAX_GEN_TOKENS=2048` | The header and the `gen_kwargs` in results json show 2048 |
| TC-18 | Category dispatch | `docker run "${COMMON[@]}" $IMG general` with a throwaway RUN_ID. Abort after GPQA starts | GPQA starts with CCU 8, and the header prints `MAX_GEN_TOKENS (all benchmarks): 65536`, `Categories: general`. With no docker socket there's no socket error, because `general` doesn't need one |
| TC-19 | Unknown category | `docker run "${COMMON[@]}" $IMG foo` | Exits 1: `Unknown category: foo` |
| TC-20 | Wrong API key | TC-06 with `-e API_KEY=invalid` | Exits ≠0 with a visible 401, and **no** results json with a 0% score. A 401 must not look like a model failure |
| TC-21 | Endpoint down | TC-06 with `OPENAI_BASE_URL=http://127.0.0.1:9/v1` | Exits ≠0 with a connection error, no score written |
| TC-22 | Two categories in parallel | `general` and `coding` in two panes, same RUN_ID (LIMIT via direct scripts) | Both finish, with no clobbering between `jobs/$RUN_ID/{gpqa,…}` and `{livecodebench,scicode}` |

## Stage 3: full-recipe acceptance (Phase 1, optional, hours)

| ID | Case | Command | Expected |
|---|---|---|---|
| TC-23 | `general` recipe | `docker run "${COMMON[@]}" $IMG general` | GPQA 198, MMLU-Pro 504, HLE 250 samples (+ judges). The summary prints `OK` for all three |
| TC-24 | `coding` recipe | `docker run "${COMMON[@]}" $IMG coding` | LCB 200 problems, SciCode 30 test problems (seed 42), both `OK` |
| TC-25 | BFCL recipe step | `docker run "${COMMON[@]}" -e TEST_CATEGORY=single_turn $IMG scripts/run_bfcl.sh` | 13 categories scored (3,641 cases) |
| TC-26 | Reproducibility vs. baseline | Run TC-23 to TC-25 on gemma4 (`google/gemma-4-31b-it`) | Scores within noise of `jobs/gemma4-31b-fp8/README.md`: GPQA 52.53%, MMLU-Pro 83.13%, HLE 12.4%. Baseline ran at the 65k recipe default, so the settings match |

## Phase 2 (planned): SWE-bench Pro and DeepSWE

Every case adds `-v /var/run/docker.sock:/var/run/docker.sock`. The jobs mount
must be at the **same path** (already in `COMMON`).

| ID | Case | Command / How | Expected |
|---|---|---|---|
| TC-30 | Socket missing | `docker run "${COMMON[@]}" $IMG scripts/run_swebench_pro.sh` | Exits 1 with the "docker.sock isn't reachable" message, before any work |
| TC-31 | Wrong jobs mount | `-v "$PWD/jobs:/app/jobs"` (no JOBS_ROOT) plus the socket, `agentic` | Exits 1: "host docker daemon can't see JOBS_ROOT" |
| TC-32 | Dataset prep plus the HF pin | First SWE-bench Pro run on a fresh volume | `prepare-swebench-pro-data.sh` generates 731-row data at revision `7ab5114`, and a `.hf-revision` stamp exists |
| TC-33 | SWE-bench Pro smoke | `-e LIMIT=4 -e WORKERS=2 -e EVAL_WORKERS=2 $IMG scripts/run_swebench_pro.sh` | `preds/preds.json` has 4 entries, `eval/` has 4 per-instance dirs plus `eval/eval_results.json`. Count resolved from `eval_results.json`, not stdout (`swebench-pro-metric-pitfalls`). No `return code: 127` |
| TC-34 | DeepSWE smoke | `$IMG scripts/run_deepswe.sh 2 2` | 2 trials with a `result.json`, and no `RewardFileNotFoundError` or `ContextWindowExceededError` (R4) |
| TC-35 | Resume | Rerun TC-33 and TC-34 | Finished instances and batches are skipped |
| TC-36 | Prune loop sidecars | Start `scripts/prune_loop.sh` (SWE-bench Pro) and `scripts/prune_deepswe_loop.sh` (DeepSWE) in sibling containers during a run | Reclaim images only for completed instances. DeepSWE p3 (2 tasks): both trial images removed right after each finished, no leftovers, quality-bench untouched |
| TC-37 | Full `agentic` recipe | `docker run "${COMMON[@]}" -v /var/run/docker.sock:/var/run/docker.sock $IMG agentic` | BFCL, SWE-bench Pro (200, CCU 4) and DeepSWE (64, CCU 8) all `OK`. Infra failures are rerun, model failures are not (`benchmark-failure-attribution`) | Covered by TC-38 (`agentic` is one of its 3 categories).
| TC-38 | Everything | `$IMG` (default CMD, all 8) | Summary lists all 8 benchmarks as `OK`. Verified with a reduced run (`imgtest-20261002-tc38b`): each of the 8 benchmarks run sequentially at CCU 4 on a small subset (GPQA 8, MMLU-Pro 2/subject, HLE 4/subtask, LCB 8, SciCode 4, BFCL `simple_python`, SWE-bench Pro 4, DeepSWE 4 tasks) -- all `rc=0`, total wall ~2h53m. Found a leftover-image race: the last DeepSWE trial finished right as the driver exited, so the periodic prune sidecar didn't get another cycle before being killed, leaving 2 stray images (~8GB). Fixed in `scripts/run_deepswe.sh`: it now runs `prune_deepswe_loop.sh --once` itself right after `pier run`/`pier job resume` returns, scoped to its own job dir, so cleanup no longer depends on an external sidecar's timing. Verified with a standalone 1-task run, no sidecar at all (`imgtest-20261002-fixcheck`): task passed (reward 1.0), rc=0, and the script's own final sweep removed both of its trial images immediately -- no leftovers. |

## Reporting

For each TC, record ID, image ID, RUN_ID, pass/fail, wall-clock, score (where
applicable), and the log excerpt for any failure. Tag each failure as one of:
**image bug** (fix before release), **endpoint/infra** (rerun), or **known
risk R1–R5**.
