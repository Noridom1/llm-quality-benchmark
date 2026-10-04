# LiveCodeBench

Competitive-programming code generation (`codegeneration` scenario) using the
OpenAI-compatible runner of the upstream `LiveCodeBench/` checkout, with sandboxed
test execution. Results land in `jobs/<RUN_ID>/livecodebench/`.

```bash
RUN_ID=my-run bash benchmarks/livecodebench/run.sh
LIMIT=4 MULTIPROCESS=2 bash benchmarks/livecodebench/run.sh   # smoke
```

| Variable | Default | Description |
|---|---|---|
| `LIMIT` | _empty_ | First N problems |
| `RELEASE_VERSION` | `release_latest` | Dataset release |
| `SCENARIO` | `codegeneration` | LCB scenario |
| `MULTIPROCESS` | `4` | Parallel generation workers |
| `NUM_PROCESS_EVALUATE` | `12` | Parallel test-evaluation processes |
| `TIMEOUT` | `6` | Per-test timeout (s) |
| `OPENAI_TIMEOUT` | `600` | Request timeout (s) |
| `TEMPERATURE` / `N` | `0.0` / `1` | Sampling |
| `MAX_TOKENS` | `65536` | Max generated tokens (`MAX_GEN_TOKENS` also accepted) |

`patches/` holds our changes to upstream (streaming, `LCB_OUTPUT_DIR`, auto-registering
`LCB_MODEL`), applied at image build time.

> **Contamination caveat:** `release_latest` can include problems published before a
> model's training cutoff. See the notes in `results/` before comparing scores.
