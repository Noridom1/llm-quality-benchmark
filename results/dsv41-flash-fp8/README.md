# Benchmark results — dsv41-flash-fp8

Model: `deepseek-ai/DeepSeek-V4.1-Flash-1017` (self-host, FP8 with FP4 experts). Run date: 2026-11-19/20.
Served with SGLang (`lmsysorg/sglang:dev-dsv41`), TP 8, `--ep-size 8 --attention-backend dsv4 --moe-runner-backend flashinfer_mxfp4`
on one H200 node (hgx-h200-01, Slurm job 18021).
Bench client image: `ghcr.io/noridom1/llm-quality-benchmark:testing`. Config matches
[glm5.3-fp8](../glm5.3-fp8/README.md): `max_gen_toks` = **65536**, same subsets, temperature 0.
Raw artifacts: `jobs/dsv41-flash-fp8/`, `jobs/dsv41-flash-fp8-nonet-{s1..s4,r1}/` on the bench host.

## Summary

| Benchmark | dsv41-flash-fp8 | glm5.3-fp8 (reference) |
|---|---|---|
| SWE-bench Pro (Pass@1, 200, network blocked) | **110/200 = 55.0%** | 139/200 = 69.5% |
| DeepSWE (reward, 64) | **42/64 = 65.6%** | 48/64 = 75.0% |
| GPQA Diamond (flexible-extract) | **90.91%** (180/198) | 85.86% |
| MMLU-Pro (504) | **87.10%** (439/504) | 86.31% |
| LiveCodeBench (Pass@1, 200) | **96.5%** (193/200) | 93.0% |
| SciCode (sub-steps / whole problem) | **49.1% / 16.67%** (5/30) | 45.6% / 13.33% |
| HLE (LLM-judge deepseek-v4-pro) | **36.8% (92/250)** | 38.4% (96/250) |
| BFCL v4 single-turn (Non-Live / Live) | **85.04% / 78.39%** | 88.29% / 80.53% |

Reading: DeepSeek is ahead on knowledge and reasoning (GPQA, MMLU-Pro, LCB, SciCode) and behind on agentic
tasks (SWE-bench Pro, DeepSWE) and on BFCL. The LCB figure carries the same contamination caveat as the GLM runs.
HLE differences of a few points on 250 questions are within noise.

## Per-benchmark notes

| Benchmark | CCU | Notes |
|---|---|---|
| GPQA | 8 | flexible-extract. Interrupted when the node was needed, resumed from the lm-eval cache. |
| MMLU-Pro | 8 | 36 q/subject x 14 subjects. Interrupted and resumed from cache. Stub answers were regenerated after the stop-sequence fix (see Caveats). |
| LiveCodeBench | 8 (MULTIPROCESS) | first 200 problems, n=1, temp 0. |
| SciCode | 8 | 30/65 problems, seed 42, without_background. 49.1% sub-steps, 5/30 whole problems. 2 generations failed. |
| HLE | 32 | 250 q. deepseek-v4-pro judge 92/250 (36.8%); qwen judge 95/250; self-judge 94/250. Interrupted and resumed from cache; stubs regenerated. |
| BFCL | 32 threads | single_turn only (`--partial-eval`). Non-Live 85.04, Live 78.39, computed from the per-category score files. The CSV "overall" and "Multi-turn" columns are invalid for this partial run and must not be quoted. |
| SWE-bench Pro | 4 shards x 10 agent, 4 x 2 eval | agent sandbox `--network none`. First pass 99/200 = 49.5%. 22 instances died on infra errors (5 CalledProcessError, 17 `No such container`). Rerun (`dsv41-flash-fp8-nonet-r1`): 13 Submitted, 9 LimitsExceeded, 11/22 pass, no regressions. Merged: 99 + 11 = **110/200 = 55.0%** (`jobs/dsv41-flash-fp8-nonet-swepro-merged200.json`). Final exit status: 157 Submitted, 43 LimitsExceeded. |
| DeepSWE | 3 | Clean run `64tasks-ccu3`: 64/64 trials completed, 42 reward=1 (65.6%). The earlier `64tasks-ccu8` run was affected by infra errors and is not used. |

## Caveats

- **Thinking is forced by a proxy.** DeepSeek enables thinking per request, so the bench host ran `dsv41_proxy.py`
  in front of the server. It injects `reasoning_effort: "high"` and drops `stop`. The model thinks very briefly.
- **Temperature 0**, versus the vendor-recommended 1.0, for comparability with the GLM runs.
- **Stop-sequence stubs.** lm-eval's `until: ["Question:"]` fired inside DeepSeek's thinking and produced stub
  answers on MMLU-Pro and HLE. The proxy now drops `stop`, and the stubs were deleted from the lm-eval caches and regenerated.
- **Format failures on SWE-bench Pro.** DeepSeek often emits its native DSML tool-call syntax instead of the single
  ```bash block that mini-swe-agent requires (about 38% of responses in the first pass were format-bad, 44% contained DSML).
  This is a model format failure. The proxy does not sanitize DSML, and the score is kept as is. Agentic scores
  should be read with this in mind.
- **Hardware difference.** H200 with FP4 experts, not the B300 nodes used for GLM, so throughput is not comparable.

## Status

All 8 benchmarks completed on DeepSeek-V4.1-Flash FP8.
