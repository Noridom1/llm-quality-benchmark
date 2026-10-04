#!/usr/bin/env bash
# Event stream for a SWE-bench Pro campaign. One stdout line == one alert.
#
# The failure count MUST come from preds.json, not from exit_statuses_*.yaml:
# that directory accumulates one yaml per launch, so a stale file from an
# aborted run makes a healthy rerun look like it has 108 failures.
# Source of truth is "entry whose model_patch is not a diff".
set -uo pipefail
cd "$(dirname "$0")/../.."
RUN_ID="${RUN_ID:?set RUN_ID}"
TOTAL="${TOTAL:-200}"
PREDS="jobs/$RUN_ID/swebench-pro/preds/preds.json"
EVALD="jobs/$RUN_ID/swebench-pro/eval"

counts() {  # -> "<preds> <bad>"
  python3 - "$PREDS" <<'PY' 2>/dev/null || echo "0 0"
import json,sys
try: d=json.load(open(sys.argv[1]))
except Exception: print("0 0"); raise SystemExit
def real(t): return "diff --git " in t or "\n--- a/" in t or t.startswith("--- a/")
print(len(d), sum(1 for v in d.values() if not real(v.get("model_patch") or "")))
PY
}

prev_bad=-1; low_armed=1; said_p1=0; said_p2=0; last_report=0
while true; do
  read -r n bad <<<"$(counts)"
  free=$(df --output=avail -BG /mnt | tail -1 | tr -dc '0-9')
  p1=0; pgrep -f "swebench_pro/runner\.py" >/dev/null 2>&1 && p1=1
  p2=0; pgrep -f "swe_bench_pro_eval\.py" >/dev/null 2>&1 && p2=1
  evals=$(ls -d "$EVALD"/*/ 2>/dev/null | wc -l)

  [[ $prev_bad -ge 0 && $bad -gt $prev_bad ]] && echo "NEW FAILURES: +$((bad-prev_bad)) (total $bad/$n)"
  prev_bad=$bad

  pgrep -f "prune_loop\.sh" >/dev/null 2>&1 || echo "WARNING: prune-loop died -- disk will fill up again"

  if [[ $free -lt 10 && $low_armed -eq 1 ]]; then
    echo "WARNING: only ${free}G left on /mnt"
    low_armed=0
  elif [[ $free -gt 30 ]]; then low_armed=1; fi

  if [[ $p1 -eq 0 && $said_p1 -eq 0 && $n -ge 1 ]]; then
    echo "PHASE 1 DONE: $n/$TOTAL preds, $bad without a patch"; said_p1=1
  fi
  if [[ $p2 -eq 1 && $said_p2 -eq 0 ]]; then
    echo "PHASE 2 (eval) started"; said_p2=1
  fi
  if [[ $said_p2 -eq 1 && $p2 -eq 0 ]]; then
    res="jobs/$RUN_ID/swebench-pro/eval/eval_results.json"
    echo "RUN COMPLETE: $evals eval outputs; see $res"
    exit 0
  fi
  if [[ $p1 -eq 0 && $p2 -eq 0 && $said_p1 -eq 1 && $said_p2 -eq 0 ]]; then
    echo "WARNING: no process is running but Phase 2 has not started"
  fi

  now=$(date +%s)
  if (( now - last_report >= 1800 )); then
    echo "progress: preds $n/$TOTAL | no-patch $bad | eval $evals | /mnt ${free}G | phase $((p1==1?1:(p2==1?2:0)))"
    last_report=$now
  fi
  sleep 60
done
