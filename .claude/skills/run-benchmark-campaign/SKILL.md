---
name: run-benchmark-campaign
description: Run the full 8-benchmark quality campaign (GPQA, MMLU-Pro, LiveCodeBench, SciCode, HLE, BFCL, SWE-bench Pro, DeepSWE) for a self-hosted model served by SGLang on the VNG Slurm cluster, driven from the bench host through a reverse SSH tunnel. Use when asked to serve a model and benchmark it, resume or rerun a campaign, debug a failed SWE-bench Pro / DeepSWE run, or write the results/<run>/README.md.
---

# Run a benchmark campaign (Slurm serve -> tunnel -> bench host)

Load `slurm-cluster` too (access, storage rules). This skill is the campaign-specific layer.

## Topology

```
Slurm GPU node (sglang :PORT) --reverse ssh -R--> bench host 127.0.0.1:18000
bench host: proxy :8081 (adds reasoning_effort, drops stop) -> :18000
            proxy :80   (same, for DeepSWE only)
            bench container (--network host) -> OPENAI_BASE_URL
```

- VM (where Claude runs) cannot reach the bench host's services directly; it runs commands over ssh.
  `S` = ssh to Slurm login node (password via `sshpass -f ~/.slurm_pass`, port 234),
  `B` = `ssh -p 234 -o BatchMode=yes phucnlt2@<bench-host>` (repo at `/data/phucnlt2/llm-quality-benchmark`).
- Bench host: 62 GB RAM, 16 cores, no sudo, UTC clock (VM is +7h). Docker socket is shared with other users' containers: only touch containers you created.
- Never print `/shared/phucnlt2/serve/<jobid>.key`, `~/.slurm_pass`, `HF_TOKEN`, or `.env`.

## 1. Serve

`deployment/slurm/serve_tunnel.sbatch` from the login node (copy it to `/shared/phucnlt2/` first). Params are env vars:

```bash
export MODEL=<hf repo> TP=<n> SQSH=<enroot .sqsh on the node> EXTRA_ARGS="<sglang args, parsers>"
sbatch --parsable -p b300-hcm -w <node> --gres=gpu:<n> --time=10:00:00 --job-name=serve-<tag> --export=ALL /shared/phucnlt2/serve_tunnel.sbatch
```

- Check first: `sinfo`, free GPUs on the node (`scontrol show node`), that the model is in `/mnt/hf_hub_cache` and the image `.sqsh` exists on THAT node (both are node-local). Other users can fill a node in minutes; if it does, pick another node and reduce TP.
- Startup is about 20 min for a 48-shard model. Watch `/shared/phucnlt2/job-logs/serve-tunnel_<id>.{out,server.log}` with Monitor, not `sleep`.
- Reasoning/tool parsers: DeepSeek V4.x needs `--reasoning-parser auto --tool-call-parser auto`. Record the exact command, node, TP and job id in the results README.
- Per-job API key is in `/shared/phucnlt2/serve/<jobid>.key`. Hand it to the bench host without printing it:
  `$S 'tr -d "\n" < /shared/phucnlt2/serve/<id>.key; echo' | $B 'bash /data/phucnlt2/<script>.sh'`, where the script does `read -r NEWKEY`.
- Test through the tunnel from the bench host (`curl 127.0.0.1:18000/v1/models` with the key) before launching anything.
- When done: `scancel <jobid>` (only yours), confirm with `squeue -u phucnlt2`.

## 2. Proxy (needed for models that think per request)

DeepSeek V4.x only thinks if the request asks. `dsv41_proxy.py` (in `/data/phucnlt2/` on the bench host) forwards to `127.0.0.1:18000`, injects `reasoning_effort: "high"` and drops `stop` (lm-eval `until: ["Question:"]` fires inside the thinking and produces stub answers). Run it on `172.17.0.1:8081`; point `OPENAI_BASE_URL` at it for everything except DeepSWE.

**DeepSWE needs a second proxy on port 80.** pier gives each trial a squid egress proxy that only allows ports 80 and 443. A base URL on `:8081` gives HTTP 403 and every trial exits `NonZeroAgentExitCodeError` with score 0 (looks like a model failure, is not). Run the same proxy on port 80 (container `dsv41-proxy80`, from the bench image, `--network host`) and use `OPENAI_BASE_URL=http://172.22.0.1/v1` for DeepSWE. Remove it when finished. Also do not touch `llm-fwd-80` (someone else's socat).

When the server changes (new job id), the key changes: the proxy passes the Authorization header through, so only the bench container env needs the new key.

## 3. Launch the benchmarks

Common env: `API_KEY OPENAI_BASE_URL MODEL_NAME RUN_ID HF_TOKEN` (+ `MSWEA_MODEL_NAME`, `MAX_GEN_TOKS`). Same config as the reference runs (`results/glm5.3-fp8`, `results/dsv41-flash-fp8`): `max_gen_toks=65536`, temperature 0, same subsets.
Run one category per container, all in `docker run -d` so they survive the SSH session. Mount `-v $PWD/jobs:$PWD/jobs` at the SAME absolute path (sibling containers bind-mount it through the host daemon) and set `JOBS_ROOT`.

| Benchmark | Subset | CCU | Notes |
|---|---|---|---|
| GPQA | 198 | 8 | flexible-extract; `HF_TOKEN` required (gated dataset) |
| MMLU-Pro | 36 q x 14 subjects = 504 | 8 | |
| LiveCodeBench | first 200, n=1 | 8 | MULTIPROCESS |
| SciCode | 30 of 65, seed 42, without_background | 8 | |
| HLE | 250 | 32 | judge = deepseek-v4-pro via `HLE_JUDGE_*`; judge is a separate endpoint |
| BFCL | `--partial-eval`, single_turn | 32 threads | quote Non-Live and Live from per-category score files; CSV overall/multi-turn are invalid for a partial run |
| SWE-bench Pro | 200, network blocked | 4 shards x 10 agent, 4 x 2 eval | see below |
| DeepSWE | 64 tasks | 3-10 | `scripts/run_deepswe.sh 64 <CCU>` |

Tip: first try the cheap ones in one container (`general coding`), run agentic ones separately. Check progress with `scripts/progress.sh` or by counting result files.

### SWE-bench Pro (network blocked)

- Mount `jobs/overrides/swebench_pro_nonet.yaml` over `/app/tasks/swebench-pro/swebench_pro.yaml` (sandbox `--network none`; the default config lets the agent reach the internet and fetch the upstream fix, which inflates scores). Name runs `<RUN_ID>-nonet-s1..s4`, `LIMIT=200`, `WORKERS`, `EVAL_WORKERS`.
- Scoring: Pass@1 over the 200 instances from `eval/eval_results.json`. Infra failures (docker exit 125 `CalledProcessError`, `No such container`, container loss) are not model failures. Collect their ids (`infra_ids*.json`), rerun just those as `<RUN_ID>-nonet-r1` with a regex filter, and merge into `jobs/<run>-nonet-swepro-merged200.json` (first pass + rerun). Report both numbers.
- Model format failures count against the model: DeepSeek often emits native DSML tool calls instead of the single ```bash block mini-swe-agent needs. Do not sanitize in the proxy. State this in the README caveats.
- **Git-history leak (audited 2026-11-27).** The instance images contain the full upstream history, including the fix commit, so `--network none` is NOT enough: agents find the fix with `git log --all`, `git branch -a`, `git show <sha>` (used in 45-166 of 200 instances; pass rate 78-86% with it vs 46-66% without). Scores from the existing runs are not comparable. For a clean run strip history inside the sandbox before the agent starts (remove remotes/branches/tags/reflog, `git gc --prune=now`, keep only HEAD) and report the git-command usage rate next to the score. Audit scripts: `/data/phucnlt2/{audit,a2,a3}.py` on the bench host.
- Also compare format-failure rates between runs (user messages starting with `Please always provide EXACTLY ONE action`, `LimitsExceeded`, empty patches) before attributing a score gap to quantization.
- If the score is far from the reference runs (e.g. +20 points), say it is unaudited. Audit per instance (trajectory length, whether a real patch was produced, no network access) before trusting it.

### DeepSWE

- Job dir is `jobs/<RUN_ID>/deepswe/<N>tasks-ccu<CCU>`. A different CCU creates a NEW dir (no resume across CCU). Same N and CCU resumes: trials with `RuntimeError`/`CancelledError` are deleted and rerun (`RETRY_ERROR_TYPES`), `NonZeroAgentExitCodeError` is kept as a failure. `config.json` is replayed, so the endpoint and key stored there are reused. Changed key or URL -> use a new job name or relaunch the container with the new env (see `relaunch_*.sh` pattern: `docker inspect` the old container's env/binds, `docker rm`, `docker run -d --network host ... scripts/run_deepswe.sh 64 <CCU>`).
- CCU: 3 was safe, 10 ran fine with about 5 GB RAM used on the 62 GB host. Check RAM (`free -g`) and subnets before raising.
- Valid check: a real trial has large token counts and nonzero f2p/p2p counts. An all-zero run with tiny tokens means the endpoint was unreachable (see 403 above).

## 4. Common failures

| Symptom | Cause / fix |
|---|---|
| DeepSWE: every trial `NonZeroAgentExitCodeError`, reward 0, 403 in agent log | Base URL not on port 80/443. Use the port-80 proxy and `http://172.22.0.1/v1`. Move the run dir aside (`...-403fail`), rerun. |
| DeepSWE: setup fails with `all predefined address pools have been fully subnetted` | Orphan compose stacks from stopped runs hold subnets. List with `docker ps -a --filter label=com.docker.compose.project`, ask the user, `docker compose down`/`docker rm -f` only YOUR stale stacks, `docker network prune`. Then relaunch. |
| DeepSWE: trial dies at image build, `public.ecr.aws` 429 | Transient rate limit. Rerun the same job (resume retries it). |
| SWE-bench Pro: `No such container` / exit 125 | Docker pressure/infra. Not a model failure. Rerun those ids (section 3). |
| SWE-bench Pro / DeepSWE all score 0, `Entryscript failed ... return code: 127` or `RewardFileNotFoundError` | `jobs` dir not mounted at the same absolute path. Fix the `-v` and `JOBS_ROOT`. |
| MMLU-Pro / HLE answers are stubs | `stop` reached the server (proxy not in the path). Delete stubs from the lm-eval cache and regenerate. |
| Model never "thinks", short answers | Proxy missing, `reasoning_effort` not set. |
| 401 after a new serve job | Key changed; relaunch the bench container with the new key. |
| Serve job pending / node full | Other users hold GPUs. Pick another node, lower TP. Image/model must exist on that node. |
| Monitor script expires or fails | Keep loops simple; avoid long foreground `sleep`. |
| Docker `rm -f` of many containers blocked | The permission classifier blocks broad cleanups. Ask the user, then remove specific named containers one by one. |
| Foreground ssh dies mid-run | Always `docker run -d`, never run a campaign inside the ssh session. |

## 5. Results README

Write `results/<run-id>/README.md` using `results/dsv41-flash-fp8/README.md` as the template: header (model, image, TP, node, Slurm job id, flags), summary table with the reference runs as columns, per-benchmark notes (CCU, counts, retries, which dirs are NOT used), caveats (thinking proxy, temperature 0, 403 incident, format failures, hardware difference), status. Keep the header in sync if the server changes mid-campaign (e.g. TP8 on one node for general, TP4 on another for agentic).

## 6. Wrap-up checklist

- `scancel` the serve job. Remove your own `proxy80` container and stale trial stacks (ask first). Delete `/data/phucnlt2/.hf_env` and temp scripts that hold keys.
- Do not commit or push unless asked. Never add a Co-Authored-By trailer in this repo (user instruction).
- Defer without go-ahead: quant comparison pages, per-instance audits, reruns, deleting other containers.
