# Benchmark results — glm5.3-fp8

Model: `zai-org/GLM-5.3` (self-host, **native FP8**). Run date: 2026-11-17/18.
Served with SGLang v0.5.23, TP 8 on one B300 node (b300-03, Slurm job 17249),
`--context-length 400000 --tool-call-parser glm47 --reasoning-parser glm45 --mem-fraction-static 0.90`.
Bench client image: `ghcr.io/noridom1/llm-quality-benchmark:testing`. Config matches
[glm5.3-nvfp4](../glm5.3-nvfp4/README.md): `max_gen_toks` = **65536**, same subsets.
Raw artifacts: `jobs/glm5.3-fp8/`, `jobs/glm5.3-fp8-nonet-{s1..s4,r1}/` on the bench host.

> **⚠️ SWE-bench Pro score is not clean (audit, 2026-11-27).** The task images contain the full upstream git history, including commits newer than the base commit, so the real fix is reachable with `git log --all` / `git branch -a` / `git show <sha>` even with `--network none`. Agents used these commands in 146 of 200 instances (pass rate 78% with git-history use vs 46% without), and some trajectories say their diff "matches the upstream fix". `LimitsExceeded` was 43/200 (empty patches), versus 20 in the NVFP4 run. Do not compare SWE-bench Pro across runs or quote it as a model-quality score until it is rerun with git history stripped. The other benchmarks (DeepSWE included) are not affected. Audit data: `audit_rows.json` on the bench host.

## Summary

| Benchmark | glm5.3-fp8 | glm5.3-nvfp4 |
|---|---|---|
| SWE-bench Pro (Pass@1, 200, network blocked) | **139/200 = 69.5%** | 164/200 = 82.0% |
| DeepSWE (reward, 64) | **48/64 = 75.0%** | 42/64 = 65.63% |
| GPQA Diamond (flexible-extract) | **85.86%** (170/198) | 88.38% |
| MMLU-Pro (504) | **86.31%** (435/504) | 87.70% |
| LiveCodeBench (Pass@1, 200) | **93.0%** (186/200) | 95.5% |
| SciCode (sub-steps / whole problem) | **45.6% / 13.33%** | 45.61% / 13.33% |
| HLE (LLM-judge deepseek-v4-pro) | **38.4% (96/250)** | 34.4% (86/250) |
| BFCL v4 single-turn (Non-Live / Live) | **88.29% / 80.53%** | 87.83% / 79.64% |

## Summary across GLM versions

| Benchmark | glm5.2 (baseline) | glm5.3 W4A-FP8 | glm5.3 NVFP4 | glm5.3 FP8 (native) |
|---|---|---|---|---|
| SWE-bench Pro (Pass@1, 200) | 109/200 = 54.5% | 133/200 = 66.5% ⚠️ network unknown | **164/200 = 82.0%** (with network: 179/200 = 89.5%) | 139/200 = 69.5% (network blocked) |
| DeepSWE (reward, 64) | 20/64 = 31.25% | 45/64 = 70.31% | 42/64 = 65.63% | **48/64 = 75.0%** |
| GPQA Diamond | 84.34% | 87.88% | **88.38%** | 85.86% |
| MMLU-Pro (504) | 84.33% | 85.32% | **87.70%** | 86.31% |
| LiveCodeBench (Pass@1, 200) | 61.31% (122/199) | 95.5% | 95.5% | 93.0% |
| SciCode (sub-steps / whole) | 40.35% / 6.67% | 40.35% / 6.67% | **45.61% / 13.33%** | 45.6% / 13.33% |
| HLE (judge deepseek-v4-pro, 250) | **38.0%** (95) | 34.4% (86) | 34.4% (86) | **38.4%** (96) |
| BFCL v4 Non-Live / Live | 88.69% / 81.94% | 88.60% / 80.16% | 87.83% / 79.64% | 88.29% / 80.53% |

Notes: LiveCodeBench 95.5% on W4A-FP8/NVFP4 is under contamination suspicion, so the 5.2 -> 5.3 gap is partly unreliable. HLE differences of a few points on 250 questions are within noise. 5.3 clearly beats 5.2 on agentic tasks (SWE-Pro, DeepSWE); the three 5.3 variants are close on GPQA, MMLU-Pro, SciCode and BFCL; NVFP4 wins SWE-Pro/GPQA/MMLU-Pro, FP8 wins DeepSWE/HLE.

## Per-benchmark notes

| Benchmark | CCU | Notes |
|---|---|---|
| GPQA | 8 | flexible-extract; strict-match 4.5% is the known lm-eval artifact. Finished 21:45 UTC 17/11. |
| MMLU-Pro | 8 | 36 q/subject x 14 subjects. Finished 22:28 UTC 17/11. |
| LiveCodeBench | 8 (MULTIPROCESS) | first 200 problems, n=1, temp 0. Same contamination caveat as nvfp4. |
| SciCode | 8 | 30/65 problems, seed 42, without_background. |
| HLE | 32 (restarted from 6, resumed from lm-eval cache) | 250 q. deepseek judge: EM 54/125 + MC 42/125 = 96/250 (38.4%); qwen3.7-plus 98/250 (39.2%); GLM self-judge 99/246 (EM/MC 55/44, kappa 0.958 vs deepseek). Generation CCU does not affect score. |
| BFCL | 32 threads | single_turn, 13/13 categories. Non-Live 88.29, Live 80.53. |
| SWE-bench Pro | 4 shards x 10 agent = 40, 4 x 2 eval | agent sandbox `--network none`. Exit status: 151 Submitted, 43 LimitsExceeded, 6 CalledProcessError (docker run failed at sandbox start, 0 steps = infra). Per shard: s1 31, s2 37, s3 35, s4 30 (of 50). Rerun of the 6 infra instances (`glm5.3-fp8-nonet-r1`): 6/6 Submitted, 6/6 pass. Merged: 133 + 6 = **139/200 = 69.5%** (`jobs/glm5.3-fp8-nonet-swepro-merged200.json`). |
| DeepSWE | 12 | Final run `64tasks-ccu12`: 64/64 trials completed, 48 reward=1 (75.0%), ~203 min wall clock, avg 137 agent steps/trial, 1.018B input / 6.69M output tokens. 1 trial (`scriggo-method-declarations`) ended with NonZeroAgentExitCodeError (agent exit 1), scored as fail (reward 0). Earlier attempts invalid: CCU 8 run had 64/64 HTTP 503 (the `172.17.0.1:80` forwarder to the tunnel was not running; fixed with an `alpine/socat` container `llm-fwd-80`); CCU 40 run had 49 RuntimeErrors (Docker default address pools exhausted: each trial creates 2 networks, so ~14 concurrent trials max without a `daemon.json` `default-address-pools` change). |

## Status

All 8 benchmarks completed on GLM-5.3 FP8. DeepSWE (75.0%) is now above NVFP4 (65.63%), while SWE-Pro is below it (69.5% vs 82.0%; 43 LimitsExceeded vs 20 for NVFP4, not investigated further).
