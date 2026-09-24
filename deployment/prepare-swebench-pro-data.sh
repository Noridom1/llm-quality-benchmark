#!/usr/bin/env bash
# Lazily materializes the two SWE-bench Pro data files that are gitignored,
# regenerable, and (for the second one) require HF_TOKEN + network -- so they
# aren't baked into the image at build time (avoids embedding a secret in a
# layer, and matches how jobs/logs are treated: the authoritative source is
# upstream/HF, this is a regenerable local cache).
#
# Idempotent: skips whatever's already present. Mount a volume over
# SWE-bench_Pro-os/data and SWE-bench_Pro-os/SWE-agent/data to persist these
# across container runs instead of regenerating every time.
#
# Exact commands per top-level README.md ("SWE-bench Pro" > "Setup", steps 3-4).
set -euo pipefail
cd /app/SWE-bench_Pro-os

PY=/app/.venv-swebenchpro/bin/python

if [[ ! -s SWE-agent/data/instances.yaml ]]; then
  echo "[prepare-swebench-pro-data] generating SWE-agent/data/instances.yaml ..."
  "$PY" helper_code/generate_sweagent_instances.py --dockerhub_username "${DOCKERHUB_USERNAME:-jefzda}"
fi

if [[ ! -s data/swebench_pro_raw_sample.jsonl ]]; then
  : "${HF_TOKEN:?HF_TOKEN is required to download ScaleAI/SWE-bench_Pro from Hugging Face}"
  echo "[prepare-swebench-pro-data] exporting data/swebench_pro_raw_sample.jsonl from HF ..."
  mkdir -p data
  HF_TOKEN="$HF_TOKEN" "$PY" - <<'PY'
import json, os
from datasets import load_dataset
ds = load_dataset("ScaleAI/SWE-bench_Pro", split="test")
out = "data/swebench_pro_raw_sample.jsonl"
with open(out, "w") as f:
    for row in ds:
        f.write(json.dumps({k: (v if isinstance(v, (str, int, float, bool)) or v is None else json.dumps(v)) for k, v in row.items()}) + "\n")
print(f"Wrote {len(ds)} rows to {out}")
PY
fi
