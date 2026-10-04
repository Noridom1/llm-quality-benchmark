#!/usr/bin/env bash
# Lazily materializes the two SWE-bench Pro data files that are gitignored,
# regenerable, and (for the second one) require HF_TOKEN + network -- so they
# aren't baked into the image at build time (avoids embedding a secret in a
# layer, and matches how jobs/logs are treated: the authoritative source is
# upstream/HF, this is a regenerable local cache).
#
# Idempotent: skips files already generated from the pinned revision. Mount a volume over
# SWE-bench_Pro-os/data and SWE-bench_Pro-os/SWE-agent/data to persist these
# across container runs instead of regenerating every time.
#
# Exact commands per top-level README.md ("SWE-bench Pro" > "Setup", steps 3-4).
set -euo pipefail
cd /app/SWE-bench_Pro-os

PY=/app/.venv-swebenchpro/bin/python

# Pin the HF dataset. Upstream's 2026-09-22 "V2" commit changed the default
# config to 642 tasks with a new test-name format that the repo's
# run_scripts/*/parser.py don't emit, so unpinned data scores nearly every
# instance false. 7ab5114 is the last 731-task (v1) commit, identical to what
# all our baselines were scored against.
export SWEBENCH_PRO_HF_REVISION="${SWEBENCH_PRO_HF_REVISION:-7ab5114912baf22bb098818e604c02fe7ad2c11f}"

# A persisted volume may hold files from another revision, so each file gets a
# <file>.hf-revision stamp and is regenerated when the stamp doesn't match.
up_to_date() {
  [[ -s "$1" && "$(cat "$1.hf-revision" 2>/dev/null)" == "$SWEBENCH_PRO_HF_REVISION" ]]
}

if ! up_to_date SWE-agent/data/instances.yaml; then
  echo "[prepare-swebench-pro-data] generating SWE-agent/data/instances.yaml ..."
  "$PY" helper_code/generate_sweagent_instances.py --dockerhub_username "${DOCKERHUB_USERNAME:-jefzda}" \
    --revision "$SWEBENCH_PRO_HF_REVISION"
  echo "$SWEBENCH_PRO_HF_REVISION" > SWE-agent/data/instances.yaml.hf-revision
fi

if ! up_to_date data/swebench_pro_raw_sample.jsonl; then
  : "${HF_TOKEN:?HF_TOKEN is required to download ScaleAI/SWE-bench_Pro from Hugging Face}"
  echo "[prepare-swebench-pro-data] exporting data/swebench_pro_raw_sample.jsonl from HF ..."
  mkdir -p data
  HF_TOKEN="$HF_TOKEN" "$PY" - <<'PY'
import json, os
from datasets import load_dataset
ds = load_dataset("ScaleAI/SWE-bench_Pro", split="test",
                  revision=os.environ["SWEBENCH_PRO_HF_REVISION"])
out = "data/swebench_pro_raw_sample.jsonl"
with open(out, "w") as f:
    for row in ds:
        f.write(json.dumps({k: (v if isinstance(v, (str, int, float, bool)) or v is None else json.dumps(v)) for k, v in row.items()}) + "\n")
print(f"Wrote {len(ds)} rows to {out}")
PY
  echo "$SWEBENCH_PRO_HF_REVISION" > data/swebench_pro_raw_sample.jsonl.hf-revision
fi
