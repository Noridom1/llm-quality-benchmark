# MMLU-Pro

Broad knowledge and reasoning multiple choice across 14 subjects (chain-of-thought,
5-shot). Task: `mmlu_pro`.

Run through lm-eval from `.venv-lmeval`. `MODEL_NAME` / `OPENAI_BASE_URL` /
`API_KEY` come from `.env` (see the [root README](../../README.md#configuration)).
Results land in `jobs/<RUN_ID>/mmlu_pro/`. Responses are streamed by
[`../_shared/lm-eval-streaming`](../_shared/lm-eval-streaming/sitecustomize.py)
so long chain-of-thought generations do not hit idle timeouts.

```bash
RUN_ID=my-run bash benchmarks/mmlu_pro/run.sh
LIMIT=2 NUM_CONCURRENT=16 bash benchmarks/mmlu_pro/run.sh   # per-subject subset
```

| Variable | Default | Description |
|---|---|---|
| `LIMIT` | _empty_ | Docs per subject (empty = all) |
| `NUM_CONCURRENT` | `4` | Parallel requests |
| `NUM_FEWSHOT` | `5` | Few-shot examples |
| `MAX_GEN_TOKENS` | `65536` | Max generated tokens |
| `REQUEST_TIMEOUT` | `1800` | HTTP timeout per request (s) |
| `TASK` | `mmlu_pro` | lm-eval task name |
