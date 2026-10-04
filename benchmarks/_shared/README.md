# Shared code

Code used by more than one benchmark. Not a benchmark itself (no `run.sh`).

- `lm-eval-streaming/sitecustomize.py`: forces `stream=True` for lm-eval's OpenAI chat
  model, consumes the SSE body, and falls back to `reasoning_content` when `content` is
  empty. Loaded via `PYTHONPATH` by `gpqa`, `mmlu_pro`, `hle` and `ifeval`.
