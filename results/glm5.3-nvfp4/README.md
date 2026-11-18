# Benchmark results — glm5.3-nvfp4

Model: `nvidia/GLM-5.3-NVFP4` (self-host, **NVFP4** quantized). Run date: 2026-11-16/17.
Served with SGLang v0.5.23 (`lmsysorg_sglang_v0.5.23.sqsh`), TP 8 on one B300 node
(b300-01, Slurm job 16466), `--quantization modelopt_fp4 --context-length 400000
--tool-call-parser glm47 --reasoning-parser glm45 --mem-fraction-static 0.90`.
Bench client: thanglq5, image `ghcr.io/noridom1/llm-quality-benchmark:testing`.

Configuration matches [glm5.3-w4afp8](../glm5.3-w4afp8/README.md) and the baseline
[glm5.2-selfhost-extended](../glm5.2-selfhost-extended/README.md): `max_gen_toks`/`max_tokens` =
**65536** for every benchmark that ran (re-verified in each result file below), same subsets.
Raw artifacts: `jobs/glm5.3-nvfp4/` (+ `jobs/glm5.3-nvfp4-s{1..4}/` with-network SWE-bench Pro shards,
`jobs/glm5.3-nvfp4-nonet-{s1..s4,r1}/` no-network SWE-bench Pro) on thanglq5.

## Summary

| Benchmark | glm5.3-nvfp4 | glm5.3-w4afp8 | glm5.2 baseline |
|---|---|---|---|
| SWE-bench Pro (Pass@1, 200, agent network blocked) | **164/200 = 82.0%** (with network: 179/200 = 89.5%) | 133/200 = 66.5% ⚠️ network unknown | 109/200 = 54.5% |
| DeepSWE (reward, 64) | **42/64 = 65.63%** | 45/64 = 70.31% | 20/64 = 31.25% |
| GPQA Diamond (flexible-extract) | **88.38%** | 87.88% | 84.34% |
| MMLU-Pro (504) | **87.70%** | 85.32% | 84.33% |
| LiveCodeBench (Pass@1, 200) | **191/200 = 95.5%** ⚠️ contamination suspicion | 191/200 = 95.5% | 122/199 = 61.31% |
| SciCode (sub-steps / whole problem) | **45.61% / 13.33%** | 40.35% / 6.67% | 40.35% / 6.67% |
| HLE (LLM-judge deepseek-v4-pro) | **34.4% (86/250)** | 34.4% (86/250) | 38.0% (95/250) |
| BFCL v4 single-turn (Non-Live / Live) | **87.83% / 79.64%** | 88.60% / 80.16% | 88.69% / 81.94% |

## SWE-bench Pro

Fixing real bugs/features in real codebases (agentic coding, multi-step, graded by running real tests).

**Subset:** first **200/731** instances (slice `0:200`) of `ScaleAI/SWE-bench_Pro` at the pinned
HF revision `7ab5114912baf22bb098818e604c02fe7ad2c11f` (731 rows). Verified: the 200 ids are
exactly the first 200 of that revision, in order — the same subset as w4afp8/baseline.
(Note: the current HF `main` of the dataset has only 642 rows; do not compare against it.)

Two runs were made. The **no-network run is the number to report**; the first run let the agent
reach the internet and is kept only for reference.

### Run 2 — agent network blocked (reported)

The agent sandbox containers were started with `--network none` (config
`jobs/overrides/swebench_pro_nonet.yaml`, mounted over the image's `swebench_pro.yaml`;
verified with `docker inspect` → `NetworkMode=none`). 67/200 trajectories hit a
"could not resolve host / network unreachable" error, so the block was effective. Evaluation
(Phase 2) is unchanged. Fresh server: Slurm job 16979 on b300-01, identical serving args.
Launcher: `run_glm53_swepro_nonet.sh`.

| Metric | Result |
|---|---|
| Pass@1 | **164/200 = 82.0%** |
| Per shard | s1 41/50, s2 40/50, s3 40/50, s4 38/50 (+5 infra reruns, see below) |
| Avg turns/instance | **87.62** (median 68; with-network run 78.06, w4afp8 72.34, baseline 59.01) |
| Total tokens | **~690.6M** (675.9M prompt + 14.65M completion), 17,524 API calls |
| Agent exit status | 177 Submitted, 20 LimitsExceeded (250 steps), 3 context-window exceeded (400K) |
| CCU | 4 shards × 10 agent workers = **40** agent, 4 × 2 = 8 eval workers |
| Wall clock | **~7h08m** (09:21 → 16:29 UTC, 17/11; agent phase ~6h, last shard's eval ~1h) |
| MAX_GEN_TOKENS | 65536 |

**Failures (36):** 24 with no usable patch (20 LimitsExceeded + 3 context-window exceeded +
1 empty submission) — model failures, counted as failures; 12 with a patch that fails tests.

**Infra reruns:** 5 instances failed at sandbox start (`docker run` exit 125 after the image had
been pruned, 0 agent steps). Rerun as `glm5.3-nvfp4-nonet-r1` (same config) — 5/5 Submitted,
5/5 pass. The merged result uses the rerun for those 5.
Merged per-instance results: `jobs/glm5.3-nvfp4-nonet-swepro-merged200.json`.

**Effect of the network** (per-instance, same 200 ids; groups from the with-network run's
GitHub-fetch classification):

| Group (in with-network run) | Instances | Pass with network | Pass without network |
|---|---|---|---|
| fetched real content from GitHub | 62 | 59 (95.2%) | **47 (75.8%)** |
| tried GitHub but failed | 15 | 13 (86.7%) | 12 (80.0%) |
| no GitHub access | 123 | 107 (87.0%) | 105 (85.4%) |
| **Total** | 200 | 179 (89.5%) | **164 (82.0%)** |

149 pass in both runs; 30 pass only with network, 15 only without (`jobs/glm5.3-nvfp4-nonet-vs-net.json`).
The drop is concentrated in the instances where the agent had fetched upstream code (−12),
confirming the leak inflated the first run by ~7.5 points; the rest is run-to-run noise.
**Even without network, 82.0% is well above w4afp8 (66.5%)** — but the w4afp8 run's network
access cannot be checked (raw trajectories gone), and it was not rerun with the network blocked.

### Run 1 — agent had internet (reference only, ⚠️ leak)

| Metric | Result |
|---|---|
| Pass@1 | 179/200 = 89.5% (inflated) |
| Avg turns/instance | 78.06 (median 62) |
| Total tokens | ~573.6M (563.6M prompt + 10.07M completion), 15,613 API calls |
| Agent exit status | 191 Submitted, 9 LimitsExceeded |
| CCU | 32 agent / 8 eval, then 4 shards × 8 agent / 2 eval (Slurm job 16466) |

The agent containers (`jefzda/sweap-images`, docker default network) had internet access, and
GLM-5.3 actively used it to fetch the upstream fix (`curl raw.githubusercontent.com/...`, GitHub
commits/search API, `pip download <pkg>==<newer>`). 62/200 trajectories fetched real GitHub
content (per-instance list: `jobs/glm5.3-nvfp4-swepro-github-fetch.json`). Merged results:
`jobs/glm5.3-nvfp4-swepro-merged200.json`. **Grading verified** for both runs: pass = all
`fail_to_pass ∪ pass_to_pass` tests `PASSED`; no instance has an empty `fail_to_pass`.

## DeepSWE

Synthetic tasks (datacurve), graded by fail→pass (f2p) and pass→pass (p2p) tests in a Docker
sandbox (with an egress proxy, unlike SWE-bench Pro).

**Subset:** **64/113 tasks** (seed-0 random subset), single batch `64tasks-ccu8`
(`64tasks-ccu8.broken-127` is an earlier attempt that crashed at startup — ignore it).

| Metric | Result |
|---|---|
| Reward (task fully passed) | **42/64 = 65.63%** (42/63 = 66.67% excluding the infra error) |
| Avg turns/task | **155.98** (w4afp8 137.81, baseline 126.27) — `n_agent_steps` in `result.json` |
| f2p (fail→pass, aggregate) | **91.66%** (2,781/3,034) — per-task mean 91.68% |
| p2p (pass→pass, aggregate) | **99.96%** (102,630/102,671) |
| Total tokens | **~1,441.7M** (1,433.1M input + 8.59M output; cache not reported) |
| CCU | 8 |
| Wall clock | **5h15m** (18:05:55 → 23:20:46, 16/11) |
| MAX_GEN_TOKENS | 65536 |

**Note:** 2 errored trials, both counted as failures (not rerun):
- `pwntools-tube-multiplexing` — **infra**: `VerifierTimeoutError` (verifier > 1800s), no reward.
- `scriggo-method-declarations` — **model**: context window exceeded (335K input + 65,536 completion > 400K) after 285 steps; verifier ran, reward 0.

f2p/p2p test totals differ from w4afp8 (3,359 / 194,104), partly because pwntools has no
verifier result; compare reward first.

## GPQA Diamond

**Subset:** full **198/198** questions, 5-shot CoT.

| Metric | Result |
|---|---|
| Accuracy (flexible-extract) | **88.38%** (175/198) |
| MAX_GEN_TOKENS | 65536 |
| CCU | 8 |
| Wall clock | **48m** (10:53 → 11:41, 16/11) |

**Note:** `strict-match` (5.56%) is the known lm-eval extraction artifact on long-CoT models — use flexible-extract.

## MMLU-Pro

**Subset:** 36 questions/subject × 14 subjects = **504/12,032**.

| Metric | Result |
|---|---|
| Overall | **87.70%** (442/504) |
| Weakest | history 63.9%, other 69.4%, psychology 80.6% |
| MAX_GEN_TOKENS | 65536 |
| CCU | 8 |
| Wall clock | **22m** (11:41 → 12:03, 16/11) |

## LiveCodeBench

**Subset:** codegeneration, `release_latest`, first **200/1,055** problems (contest dates
2023-05-07 → 2024-07-06), same 200 as previous runs. n=1, temperature 0.

| Metric | Result |
|---|---|
| Pass@1 | **191/200 = 95.5%** (all 200 evaluated, no lost denominator this time) |
| By difficulty | easy 66/66 (100%), medium 95/97 (97.9%), hard 30/37 (81.1%) |
| MAX_GEN_TOKENS | 65536 |
| CCU | 8 (MULTIPROCESS) |
| Wall clock | **52m** (generation + eval, 10:53 → 11:45, 16/11) |

**Failures (9):** 8 have no code (7 with empty model output — likely the reasoning used the whole
budget/content empty; 1 with output but no extractable code), 1 genuine runtime error (`3344`).
The race-condition grading bug noted for w4afp8 did not show up (all other failures are "no code").

**⚠️ Same contamination suspicion as w4afp8:** ~95% on a long-public 2023-2024 problem set;
rerun with a `RELEASE_VERSION` newer than GLM-5.3's training cutoff before reporting.

## SciCode

**Subset:** test split, without_background, **30/65** problems (shuffle seed 42), same as previous runs.

| Metric | Result |
|---|---|
| Sub-steps correct | **45.61%** (52/114) |
| Whole problem correct | **13.33%** (4/30) |
| Total tokens | *(not logged — `model_usage` empty in the .eval log)* |
| MAX_GEN_TOKENS | 65536 (confirmed in the .eval generate config) |
| CCU | 8 |
| Wall clock | **1h48m** (11:46 → 13:34, 16/11) |

## HLE (Humanity's Last Exam)

**Subset:** **250/2,158** text-only questions (first 125 exact-match + 125 multiple-choice), same as previous runs.

| Grading method | Result |
|---|---|
| Raw string-match (flexible-extract) | 25.2% (EM 20.8%, MC 29.6%) |
| **LLM-judge (deepseek-v4-pro, used for reporting)** | **34.4% (86/250)** — EM 49/125, MC 37/125 |

**Judge cross-check:** qwen3.7-plus = 89/250 (35.6%), κ vs deepseek 0.956 (243/248 agree).
Self-judge GLM-5.3-NVFP4 = 89/248 graded, κ vs deepseek 0.956, vs qwen 0.982 — no self-grading bias.
61 responses (48 EM + 13 MC) were clipped to 24,000 chars before judging.

| Metric | Result |
|---|---|
| MAX_GEN_TOKENS | 65536 |
| CCU | 6 |
| Wall clock | generation **3h30m** (12:03 → 15:33, 16/11); judge deepseek 9m12s |

## BFCL v4 (function calling)

The ability to call functions/tools with correct syntax at the right time, given a list of available functions.

**Subset:** single-turn only (`TEST_CATEGORY=single_turn`), all **13/13 categories** =
**3,641/4,706 test cases**, same as w4afp8/baseline. Run on 2026-11-17 against a fresh
server (Slurm job 16979, b300-01, identical serving args), `run_glm53_bfcl.sh`.
All 3,641 entries generated, no API errors.

| Category | Accuracy |
|---|---|
| Non-Live Overall (AST) | **87.83%** |
| — simple (macro-avg Python/Java/JS) | 78.33% (Python 95.00% [380/400], JS 78.00% [39/50], Java 62.00% [62/100]) |
| — multiple | 93.00% (186/200) |
| — parallel | 91.50% (183/200) |
| — parallel-multiple | 88.50% (177/200) |
| — irrelevance detection | 68.75% (165/240) |
| Live Overall (AST, weighted) | **79.64%** |
| — simple | 84.88% (219/258) |
| — multiple | 78.73% (829/1053) |
| — parallel | 68.75% (11/16) |
| — parallel-multiple | 70.83% (17/24) |
| — relevance detection | 87.50% (14/16) |
| — irrelevance detection | 70.81% (626/884) |
| MAX_GEN_TOKENS | 65536 |
| CCU | 32 (`NUM_THREADS=32`; ran concurrently with the SWE-bench Pro no-network rerun) |
| Wall clock | **~48m** (09:21 → 10:09 UTC, 17/11) |

**Note:** the wrapper's one-line summary ("Overall Acc 23.73%, Non-Live AST 40.4…") is
misaligned/unusable because multi-turn/agentic were not run — read `data_non_live.csv` /
`data_live.csv`. Versus w4afp8 (88.60 / 80.16) and baseline (88.69 / 81.94): within ~1–2 points,
no sign of a quantization problem.
