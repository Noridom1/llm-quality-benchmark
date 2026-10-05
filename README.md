# LLM Quality Benchmarks

A harness for measuring the quality of any LLM served behind an OpenAI-compatible
endpoint. It runs eight benchmarks (knowledge/reasoning, code generation, tool
use, and two agentic software-engineering suites) with one consistent interface,
either from a prebuilt Docker image or directly from this checkout.

| Benchmark | Directory | Type | Sandbox |
|---|---|---|---|
| GPQA-Diamond | [`benchmarks/gpqa`](benchmarks/gpqa/) | Reasoning MCQ | None |
| MMLU-Pro | [`benchmarks/mmlu_pro`](benchmarks/mmlu_pro/) | Reasoning MCQ | None |
| HLE | [`benchmarks/hle`](benchmarks/hle/) | Reasoning QA (LLM-judged) | None |
| SciCode | [`benchmarks/scicode`](benchmarks/scicode/) | Scientific coding | Sandboxed Python |
| LiveCodeBench | [`benchmarks/livecodebench`](benchmarks/livecodebench/) | Competitive coding | Sandboxed tests |
| BFCL v4 | [`benchmarks/bfcl`](benchmarks/bfcl/) | Function/tool calling | None (AST) |
| SWE-bench Pro | [`benchmarks/swebench_pro`](benchmarks/swebench_pro/) | Agentic SE | Docker per instance |
| DeepSWE | [`benchmarks/deepswe`](benchmarks/deepswe/) | Agentic SE | Docker per task |

IFEval ([`benchmarks/ifeval`](benchmarks/ifeval/)) is included as an extra and is not part of the core eight.
Each directory has its own README with env vars, result layout and caveats.

## Docker image

Build once, then run any benchmark on any machine with Docker by supplying an
endpoint, a key and a model name. No per-benchmark virtualenvs to install. See
[`deployment/README.md`](deployment/README.md) for the build and the env/volume
contract, and [`docs/running-via-docker.md`](docs/running-via-docker.md) for the
operational playbook.

```bash
docker build -f deployment/Dockerfile -t quality-bench:latest .
# or pull the published image (pin the digest for a reproducible run):
docker pull ghcr.io/noridom1/llm-quality-benchmark:testing
docker pull ghcr.io/noridom1/llm-quality-benchmark@sha256:a4a7809dd74e...
```

### Image versions

Registry: [`ghcr.io/noridom1/llm-quality-benchmark`](https://github.com/users/Noridom1/packages/container/package/llm-quality-benchmark)

| Tag | Image ID | Built (UTC) | Source commit | Size | Invocation | Notes |
|---|---|---|---|---|---|---|
| `testing` (latest published; also tagged locally as `quality-bench:latest`) | `sha256:a4a7809dd74e` | 2026-10-02 17:31 | `65544d1` | 17.4 GB (5.14 GB compressed content) | `scripts/run_<bench>.sh` | Adds the fixes found by [`docs/image-test-plan.md`](docs/image-test-plan.md): build dependency gaps, `JOBS_ROOT` for sibling containers, pinned SWE-bench Pro dataset revision, BFCL/LiveCodeBench model auto-registration, independent HLE judge endpoint, 65536 default max tokens. |
| `smoke` (local only) | `sha256:659d6522cb81` | 2026-09-24 09:47 | `34b967b` | 15.7 GB | `scripts/run_<bench>.sh` | First image. Superseded: has the build dependency gaps, no `JOBS_ROOT`, no dataset pin. |
| _unreleased_ | n/a | n/a | this branch | n/a | `<bench>` or `benchmarks/<bench>/run.sh` | Repository restructure (per-benchmark directories). Script paths changed, so the next build should get a new version tag. |

Notes:

- `testing` is a mutable tag. Pin a digest (`ghcr.io/noridom1/llm-quality-benchmark@sha256:a4a7809dd74e...`) when you need a reproducible run, and record the image ID with your results.
- Images are matched to commits by comparing their `/app/scripts`, `/app/tasks`, `/app/patches` and `deployment/` contents with the repo history.
- Going forward, tag every build with an immutable version (`vMAJOR.MINOR.PATCH`) and add a row here in the same commit as the Dockerfile or script change.

## Running directly

```bash
git clone <this repo> && cd <repo>
cp .env.example .env        # then fill it in, see Configuration
```

Direct runs need each benchmark's upstream checkout and virtualenv next to this
repo. They are gitignored; `scripts/setup_upstream.sh` clones each upstream at
its pinned commit, applies our patch series and builds the venv — the same
steps the Dockerfile performs at image build time:

```bash
scripts/setup_upstream.sh gpqa        # lm-eval venv only (gpqa/mmlu_pro/hle/ifeval)
scripts/setup_upstream.sh bfcl lcb    # chosen benchmarks
scripts/setup_upstream.sh all         # everything (bfcl pulls a multi-GB CUDA wheel)
```

| Benchmark | Upstream (pinned) | Patches | Python | Venv |
|---|---|---|---|---|
| GPQA, MMLU-Pro, HLE, IFEval | none (lm-eval 0.4.12 from PyPI) | — | 3.12 | `.venv-lmeval` |
| BFCL v4 | `ShishirPatil/gorilla` @ `6ea5797` | [`benchmarks/bfcl/patches/`](benchmarks/bfcl/patches/) | 3.10 | `BFCL/berkeley-function-call-leaderboard/.venv-bfcl` |
| LiveCodeBench | `LiveCodeBench/LiveCodeBench` @ `28fef95` | [`benchmarks/livecodebench/patches/`](benchmarks/livecodebench/patches/) | 3.11 | `LiveCodeBench/.venv-lcb` |
| SciCode | `scicode-bench/SciCode` @ `e3158ea` | none | 3.12 | `.venv-scicode` |
| SWE-bench Pro | `scaleapi/SWE-bench_Pro-os` @ `ca10a60` (+ `SWE-agent` @ `402a7b8`, `mini-swe-agent` @ `d74716a`) | [`benchmarks/swebench_pro/patches/`](benchmarks/swebench_pro/patches/) | 3.11 | `.venv-swebenchpro` |
| DeepSWE | vendored in-repo (`deep-swe/`) | — | pier (uv tool, fetched on first run) | — |

Notes for direct runs:

- Prereqs: `git` and [`uv`](https://docs.astral.sh/uv/getting-started/installation/).
- SciCode also needs `SciCode/eval/data/test_data.h5` (~1 GB, no programmatic
  source — manual download, see SciCode's README); the setup script warns if
  it's missing.
- The agentic benchmarks (SWE-bench Pro, DeepSWE) need a working `docker`
  CLI + daemon at run time for their per-instance containers, and
  SWE-bench Pro generates its dataset on first run (`HF_TOKEN` required).
- To set one up by hand instead, follow the per-benchmark stages in
  [`deployment/Dockerfile`](deployment/Dockerfile) — the script mirrors them
  exactly, and the pins live in both places.

```bash
RUN_ID=my-model bash benchmarks/gpqa/run.sh                    # one benchmark
LIMIT=20 bash benchmarks/gpqa/run.sh                           # smoke subset
RUN_ID=my-model bash scripts/run_main_benchmark.sh             # the vetted recipe, all 8
RUN_ID=my-model bash scripts/run_main_benchmark.sh general     # one category
```

From the image: `docker run ... quality-bench:latest gpqa`, or with no argument for the
full recipe. See `deployment/README.md`.

## Configuration

Set in `.env` (or `-e` for Docker):

- `API_KEY`: API key for the OpenAI-compatible endpoint.
- `OPENAI_BASE_URL`: endpoint base, keep the `/v1`.
- `MODEL_NAME`: model id (an `openai/` prefix is accepted and stripped), e.g. `z-ai/glm-5.2`.
- `HF_TOKEN`: HuggingFace read token. Required for gated datasets such as GPQA.
- `RUN_ID`: optional; outputs go to `jobs/<RUN_ID>/<benchmark>/`. Defaults to a slug of the model name.
- `HLE_MAIN_JUDGE`: optional; model that grades HLE and produces the score
  (default `deepseek/deepseek-v4-pro`). Must differ from `MODEL_NAME`: a model grading its
  own answers is not a defensible score, and `benchmarks/hle/judge.sh` refuses to.
- `HLE_SECOND_JUDGE`: optional; independent cross-check judge (default `qwen/qwen3.7-plus`). Empty means a single judge.
- `HLE_SELF_JUDGE`: optional; `1` (default) also has the model under test grade itself, to measure self-judging bias. Never a number to report; `0` skips it.
- `HLE_JUDGE_BASE_URL` / `HLE_JUDGE_API_KEY`: optional endpoint and key for the independent HLE judges, for when the endpoint under test doesn't serve them (for example a self-hosted single-model deployment). Both default to `OPENAI_BASE_URL` / `API_KEY`. The self-judge always uses the main endpoint.

## Repository layout

```
benchmarks/<name>/    one directory per benchmark: run.sh, README, patches, task defs, helpers
benchmarks/_shared/   code used by several benchmarks (lm-eval streaming shim)
scripts/              cross-benchmark orchestration (main recipe, smoke test, progress)
deployment/           Dockerfile and container entrypoint
docs/                 recipes, run-time estimates, image playbook and test plan, benchmark survey
results/<model>/      tracked score summaries for models evaluated so far
reports/              HTML/PNG comparison pages
jobs/  logs/          run outputs (gitignored)
BFCL/ LiveCodeBench/ SciCode/ SWE-bench_Pro-os/ deep-swe/   upstream checkouts (gitignored)
```

Upstream harnesses are never committed. Our modifications to them are stored as
patch series in `benchmarks/<name>/patches/` and applied on a fresh, pinned
upstream clone at image build time.

## Adding a benchmark

Create `benchmarks/<name>/` with a `run.sh` and a `README.md`, then register it in
the Dockerfile and the main recipe. The full checklist is in
[`benchmarks/README.md`](benchmarks/README.md#adding-a-benchmark).

## Docs

- [`docs/quality-benchmark-recipes.md`](docs/quality-benchmark-recipes.md): the vetted settings per benchmark
- [`docs/BENCHMARK_TIMES.md`](docs/BENCHMARK_TIMES.md): run-time estimates and subset commands
- [`docs/running-via-docker.md`](docs/running-via-docker.md): operating the image
- [`docs/image-test-plan.md`](docs/image-test-plan.md): release-readiness test plan
- [`docs/benchmark-survey.csv`](docs/benchmark-survey.csv): survey of candidate benchmarks
- [`results/`](results/): scores for models evaluated so far
