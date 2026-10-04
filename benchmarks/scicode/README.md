# SciCode

Scientific code generation, run through `inspect-ai` from `.venv-scicode` against
the upstream `SciCode/` checkout. Needs `SciCode/eval/data/test_data.h5` (~1 GB,
manual download, see upstream README). Results land in `jobs/<RUN_ID>/scicode/`.

```bash
RUN_ID=my-run bash benchmarks/scicode/run.sh
LIMIT=4 SPLIT=validation MAX_CONNECTIONS=2 bash benchmarks/scicode/run.sh   # smoke
```

| Variable | Default | Description |
|---|---|---|
| `SPLIT` | `test` | `validation` (15 problems) or `test` (65) |
| `LIMIT` | _empty_ | First N problems |
| `MAX_CONNECTIONS` | `4` | Parallel model connections |
| `WITH_BACKGROUND` | `False` | Include the problem background text in prompts |
| `MAX_TOKENS` | `65536` | Max generated tokens (`MAX_GEN_TOKENS` also accepted) |
| `RETRY_ON_ERROR` | `2` | inspect retries per sample |
| `INSPECT_CLIENT_TIMEOUT` | `1800` | Client timeout (s) |

Other files: `retry.sh` re-runs samples that errored; `ci_run.sh` is the
external-CI variant (reads `QUALITY_*` env vars instead of `.env`);
`streaming/sitecustomize.py` streams responses to avoid idle timeouts.
