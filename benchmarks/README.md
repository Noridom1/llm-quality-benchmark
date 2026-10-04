# Benchmarks

One directory per benchmark. Everything that belongs to a benchmark lives in its
directory, so adding one means adding one directory (plus a few registration
lines, listed below).

| Directory | Benchmark | Type | Sandbox | Core 8 |
|---|---|---|---|---|
| [`gpqa/`](gpqa/) | GPQA-Diamond | Reasoning MCQ | None | yes |
| [`mmlu_pro/`](mmlu_pro/) | MMLU-Pro | Reasoning MCQ | None | yes |
| [`hle/`](hle/) | Humanity's Last Exam | Reasoning QA, LLM-judged | None | yes |
| [`scicode/`](scicode/) | SciCode | Scientific coding | Sandboxed Python | yes |
| [`livecodebench/`](livecodebench/) | LiveCodeBench | Competitive coding | Sandboxed tests | yes |
| [`bfcl/`](bfcl/) | BFCL v4 | Function/tool calling | None (AST) | yes |
| [`swebench_pro/`](swebench_pro/) | SWE-bench Pro | Agentic SE | Docker per instance | yes |
| [`deepswe/`](deepswe/) | DeepSWE | Agentic SE | Docker per task | yes |
| [`ifeval/`](ifeval/) | IFEval | Instruction following | None | no (extra) |
| [`_shared/`](_shared/) | Code shared by several benchmarks (not a benchmark) | | | |

## Directory contract

```
benchmarks/<name>/
  run.sh          # required. Entry point; `cd`s to the repo root, sources .env,
                  #   writes to jobs/<RUN_ID>/<name>/
  README.md       # required. What it measures, env vars, results layout, caveats
  patches/*.patch # optional. Changes to an upstream checkout, applied at image build
  tasks/          # optional. lm-eval task YAMLs
  streaming/      # optional. sitecustomize.py shims for streaming
  *.sh / *.py     # optional. Benchmark-specific helpers (judges, pruners, retries)
```

Every `run.sh` follows the same conventions:

- Reads `API_KEY`, `OPENAI_BASE_URL`, `MODEL_NAME` from `.env`; strips the `openai/` prefix itself.
- `RUN_ID` defaults to a slug of the model name; outputs go under `jobs/<RUN_ID>/<name>/`
  (or `$JOBS_ROOT/...` when benchmarks spawn sibling containers).
- `LIMIT` selects a smoke-test subset; `MAX_GEN_TOKENS` defaults to `65536`.
- Exits non-zero on failure, so orchestrators can report it.

## Adding a benchmark

1. **Create `benchmarks/<name>/`** with `run.sh` and `README.md` following the contract above.
   Copy the closest existing benchmark (`gpqa/` for an lm-eval task, `bfcl/` for an
   upstream harness, `deepswe/` for a Docker-per-task agent).
2. **Upstream harness (if any):** add its checkout directory to `.gitignore` and
   `.dockerignore`, and put local modifications in `benchmarks/<name>/patches/`
   rather than committing the checkout.
3. **Docker image:** add a build stage in `deployment/Dockerfile` (pinned upstream commit,
   `COPY benchmarks/<name>/patches/`, own venv) and a `COPY --from=` line in the
   `runtime` stage. `benchmarks/` itself is already copied wholesale.
4. **Entrypoint:** if it launches sibling containers, add its name to `needs_docker()` in
   `deployment/entrypoint.sh`. `docker run <image> <name>` works automatically for
   any directory that has a `run.sh`.
5. **Main recipe:** to include it in the default run, add it to a category in
   `scripts/run_main_benchmark.sh` (and `scripts/run_all_smoke_sequential.sh`).
6. **Docs:** add a row to the table above and in the root `README.md`, and a case to
   `docs/image-test-plan.md`.
7. **Verify:** `LIMIT=2 bash benchmarks/<name>/run.sh` locally, then from the built image.
