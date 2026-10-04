# GPQA-Diamond

Graduate-level science multiple choice (chain-of-thought, 5-shot). Task:
`gpqa_diamond_cot_n_shot`. Needs `HF_TOKEN` (gated dataset).

Run through lm-eval from `.venv-lmeval`. `MODEL_NAME` / `OPENAI_BASE_URL` /
`API_KEY` come from `.env` (see the [root README](../../README.md#configuration)).
Results land in `jobs/<RUN_ID>/gpqa/`. Responses are streamed by
[`../_shared/lm-eval-streaming`](../_shared/lm-eval-streaming/sitecustomize.py)
so long chain-of-thought generations do not hit idle timeouts.

```bash
RUN_ID=my-run bash benchmarks/gpqa/run.sh
LIMIT=20 NUM_CONCURRENT=8 bash benchmarks/gpqa/run.sh   # subset
```

| Variable | Default | Description |
|---|---|---|
| `LIMIT` | _empty_ | First N questions (empty = all 198) |
| `NUM_CONCURRENT` | `4` | Parallel requests |
| `NUM_FEWSHOT` | `5` | Few-shot examples |
| `SAMPLE_SEED` | `42` | Seed for the few-shot sample |
| `MAX_GEN_TOKENS` | `65536` | Max generated tokens |
| `REQUEST_TIMEOUT` | `1800` | HTTP timeout per request (s) |
| `TASK` | `gpqa_diamond_cot_n_shot` | lm-eval task name |
