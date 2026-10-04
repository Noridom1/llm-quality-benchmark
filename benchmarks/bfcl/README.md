# BFCL v4 (Berkeley Function-Calling Leaderboard)

Function/tool-calling accuracy, AST-checked (no sandbox). Uses the upstream
`BFCL/berkeley-function-call-leaderboard` checkout and `.venv-bfcl`. Any
OpenAI-compatible model works: `run.sh` sets `BFCL_MODEL`, and our patch registers
`<model>-FC` / `-PROMPT` at import. Results land in `jobs/<RUN_ID>/bfcl/`.

```bash
RUN_ID=my-run bash benchmarks/bfcl/run.sh
TEST_CATEGORY=simple_python NUM_THREADS=2 bash benchmarks/bfcl/run.sh   # smoke
```

| Variable | Default | Description |
|---|---|---|
| `TEST_CATEGORY` | `simple_python,multiple,parallel,parallel_multiple,irrelevance` | Categories (the main recipe uses `single_turn`) |
| `BFCL_MODE` | `FC` | `FC` (native tool calls) or `PROMPT` |
| `NUM_THREADS` | `4` | Parallel requests |
| `TEST_CASE_IDS` | _empty_ | Run specific case ids |
| `MAX_GEN_TOKENS` | `65536` | Max generated tokens |
| `OPENAI_TIMEOUT` | `600` | Request timeout (s) |
| `TEMPERATURE` | `0.0` | Sampling temperature |
| `FULL_EVAL` | `0` | `1` = also run the full evaluation pass |

> **Reading scores:** BFCL's `Overall Acc` is averaged over every category, so a
> category subset drags it toward 0. Read the per-category score JSONs under
> `jobs/<RUN_ID>/bfcl/score/`.
