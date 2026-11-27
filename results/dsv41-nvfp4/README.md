# Benchmark results — dsv41-nvfp4

Model: `nvidia/DeepSeek-V4.1-Flash-1017-NVFP4` (self-host, NVFP4). Run date: 2026-11-24/25.
Served with SGLang (`lmsysorg/sglang:nightly-dev-cu13-20261121-a8ac8659`) on B300 nodes: TP 8 on b300-01 (Slurm job 18741) for
the non-agentic benchmarks, TP 4 on b300-02 (job 21392) for DeepSWE and the SWE-bench Pro rerun. Flags: `--kv-cache-dtype fp8_e4m3 --dsv4-attn-backend flashmla --mem-fraction-static 0.9
--engram-config '{"placement":"cpu","replication":"none","lookup":"auto"}' --reasoning-parser auto --tool-call-parser auto`.
Bench client image: `ghcr.io/noridom1/llm-quality-benchmark:testing`. Config matches
[dsv41-flash-fp8](../dsv41-flash-fp8/README.md): `max_gen_toks` = **65536**, same subsets, temperature 0.
Raw artifacts: `jobs/dsv41-nvfp4/`, `jobs/dsv41-nvfp4-nonet-{s1..s4}/` on the bench host.

> **⚠️ SWE-bench Pro score is not clean (audit, 2026-11-27).** The task images contain the full upstream git history, including commits newer than the base commit, so the real fix is reachable with `git log --all` / `git branch -a` / `git show <sha>` even with `--network none`. Agents used these commands in 111 of 200 instances (pass rate 86% with git-history use vs 66% without), and some trajectories say their diff "matches the upstream fix". Also, the FP8 comparison is confounded by tool-call format failures: FP8 had 35 format errors per instance (150 instances with DSML, 46 empty patches, 43 `LimitsExceeded`) versus 4.2 for NVFP4 (87, 3, 2), so most of the +22 point gap is format handling, not quantization. Do not compare SWE-bench Pro across runs or quote it as a model-quality score until it is rerun with git history stripped. The other benchmarks (DeepSWE included) are not affected. Audit data: `audit_rows.json` on the bench host.

## Summary

| Benchmark | dsv41-nvfp4 | dsv41-flash-fp8 | glm5.3-fp8 |
|---|---|---|---|
| SWE-bench Pro (Pass@1, 200, network blocked) | **154/200 = 77.0%** | 110/200 = 55.0% | 139/200 = 69.5% |
| DeepSWE (reward, 64) | **45/64 = 70.3%** | 42/64 = 65.6% | 48/64 = 75.0% |
| GPQA Diamond (flexible-extract) | **88.89%** (176/198) | 90.91% | 85.86% |
| MMLU-Pro (504) | **87.10%** (439/504) | 87.10% | 86.31% |
| LiveCodeBench (Pass@1, 200) | **96.0%** (192/200) | 96.5% | 93.0% |
| SciCode (sub-steps / whole problem) | **50.9% / 13.33%** (4/30) | 49.1% / 16.67% | 45.6% / 13.33% |
| HLE (LLM-judge deepseek-v4-pro) | **40.8% (102/250)** | 36.8% | 38.4% |
| BFCL v4 single-turn (Non-Live / Live) | **84.40% / 75.87%** | 85.04% / 78.39% | 88.29% / 80.53% |

Reading: NVFP4 stays within noise of FP8 on knowledge and reasoning (GPQA -2.0, MMLU-Pro 0.0, LCB -0.5,
SciCode sub-steps +1.8, HLE +4.0). GPQA, SciCode whole-problem and HLE move by a few questions on small
sets (198 / 30 / 250), so those differences are not significant. BFCL is the only place with a consistent
drop (Non-Live -0.6, Live -2.5), still small. SWE-bench Pro is far above FP8 (+22 points) and has not been audited, so read it with caution; DeepSWE is +4.7 over FP8.

## Per-benchmark notes

| Benchmark | Notes |
|---|---|
| GPQA | flexible-extract filter, 198 questions, 176 correct. |
| MMLU-Pro | 36 q/subject x 14 subjects = 504, 439 correct. |
| LiveCodeBench | first 200 problems, n=1, temp 0. 192/200 pass. Same contamination caveat as the GLM runs. |
| SciCode | 30/65 problems, seed 42, without_background. 50.9% sub-steps, 4/30 whole problems. |
| HLE | 250 q. deepseek-v4-pro judge: 102/250 (40.8%). |
| BFCL | single_turn only (`--partial-eval`). Non-Live 84.40, Live 75.87, computed from the per-category score files. The CSV "overall" and "Multi-turn" columns are invalid for this partial run and must not be quoted. |
| SWE-bench Pro | agent sandbox `--network none`, 4 shards. First pass 200 trajectories; 5 instances died on infra errors (3 docker exit-125 `CalledProcessError`, 2 container loss: vuls, qutebrowser, flipt, ansible, element-web). Rerun (`dsv41-nvfp4-nonet-r1`): 2/5 pass (ansible, qutebrowser). Merged: **154/200 = 77.0%** (`jobs/dsv41-nvfp4-nonet-swepro-merged200.json`). Per-instance comparison with FP8 not done; the jump over FP8 (55.0%) and GLM (69.5%) has not been audited. |
| DeepSWE | CCU 10. Clean run `64tasks-ccu10`: 64/64 trials graded, 45 reward=1 (**70.3%**). Two trials (pebble, valibot) ended with `NonZeroAgentExitCodeError` and are counted as failures, as in the FP8 run. One valibot trial first died on a `public.ecr.aws` 429 during image build; it was rerun via resume. Earlier attempts are not used: `64tasks-ccu3-403fail` (port 8081 blocked by the squid egress proxy), `64tasks-ccu3-subnetfail` (Docker address pools exhausted by orphan stacks), `64tasks-ccu3` and `64tasks-ccu6` (stopped/partial). Server for this run: TP 4 on b300-02 (job 21392). |

## Caveats

- **Thinking is forced by a proxy.** Same `dsv41_proxy.py` as the FP8 run: injects `reasoning_effort: "high"`
  and drops `stop` (so lm-eval's `until` cannot cut the thinking and create stub answers).
- **Temperature 0**, versus the vendor-recommended 1.0, for comparability with the GLM and FP8 runs.
- **DeepSWE 403 incident.** pier's per-trial squid egress proxy only allows ports 80/443, so a model base URL on
  port 8081 was rejected (403) and every agent exited with `NonZeroAgentExitCodeError`. Fixed by serving the
  proxy on port 80 (`http://172.22.0.1/v1`). The 403 run scored 0 on every task and is excluded.
- **Format failures count against the model.** As in the FP8 run, native DSML tool-call syntax that mini-swe-agent
  cannot parse is not sanitized.
- **BFCL error strings.** The BFCL result files contain "error" strings in some categories (live_irrelevance,
  live_multiple, non_live irrelevance). They were not examined; the scores above are taken as produced.
- **Hardware / stack difference.** B300 + NVFP4 + a dev nightly SGLang image, versus H200 + FP4 experts for the
  FP8 run, so throughput is not comparable.

## Status

All 8 benchmarks completed on DeepSeek-V4.1-Flash-1017-NVFP4. SWE-bench Pro (77.0%) has not been audited per instance.
