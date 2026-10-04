# IFEval

Instruction-following with verifiable constraints. **Not part of the core 8** and not
run by `scripts/run_main_benchmark.sh`; kept as an example of a lightweight extra
benchmark.

Run through lm-eval from `.venv-lmeval`. `MODEL_NAME` / `OPENAI_BASE_URL` /
`API_KEY` come from `.env` (see the [root README](../../README.md#configuration)).
Results land in `jobs/<RUN_ID>/ifeval/`. Responses are streamed by
[`../_shared/lm-eval-streaming`](../_shared/lm-eval-streaming/sitecustomize.py)
so long chain-of-thought generations do not hit idle timeouts.

```bash
RUN_ID=my-run bash benchmarks/ifeval/run.sh
```

Variables: `LIMIT`, `NUM_CONCURRENT` (default `4`), `MAX_GEN_TOKENS` (`65536`),
`REQUEST_TIMEOUT` (`1800`), `TASK` (`ifeval`).
