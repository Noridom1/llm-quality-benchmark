#!/usr/bin/env python3
"""Drop failed Phase-1 entries from a SWE-bench Pro preds.json so a re-run retries them.

mini-swe-agent's process_instance() writes an entry to preds.json for *every*
instance, including ones that crashed (e.g. TimeoutExpired while pulling the
docker image) -- the exception message ends up in "model_patch". Because
swebench_pro/runner.py skips any instance_id already present in preds.json, a
plain re-run would treat those failures as done and never retry them.

This script removes the entries whose model_patch is not a real diff, so the
next `benchmarks/swebench_pro/run.sh` with the same RUN_ID picks them up again.
It also deletes the matching jobs/<RUN_ID>/swebench-pro/eval/<uid>/ directories,
because Phase 2 skips any instance that already has an <prefix>_output.json and
would otherwise keep the stale "failed" result from the junk patch.

Usage:
    python benchmarks/swebench_pro/prune_failed_preds.py jobs/<RUN_ID>/swebench-pro/preds/preds.json
    python benchmarks/swebench_pro/prune_failed_preds.py .../preds.json --apply
    python benchmarks/swebench_pro/prune_failed_preds.py .../preds.json --apply --keep-empty
"""

import argparse
import json
import shutil
import subprocess
import sys
from pathlib import Path


def is_real_patch(text: str) -> bool:
    """True if the recorded model_patch actually contains a diff.

    Deliberately permissive: some agents wrap the diff in `git diff --stat`
    output, so we look for a hunk header anywhere rather than at the start.
    """
    return "diff --git " in text or "\n--- a/" in text or text.startswith("--- a/")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("preds", type=Path, help="Path to preds.json")
    parser.add_argument("--apply", action="store_true", help="Actually rewrite the file (default: dry run)")
    parser.add_argument(
        "--keep-empty",
        action="store_true",
        help="Keep entries with an empty patch (agent ran but produced no diff) and drop only errored ones",
    )
    parser.add_argument("--force", action="store_true", help="Prune even if a Phase-1 run looks active")
    parser.add_argument(
        "--eval-dir",
        type=Path,
        default=None,
        help="Phase-2 eval dir whose per-instance results should be dropped too "
        "(default: <preds parent>/../eval, pass 'none' to keep them)",
    )
    args = parser.parse_args()

    running = subprocess.run(
        ["pgrep", "-f", "swebench_pro/runner.py"], capture_output=True, text=True
    ).stdout.split()
    if running and not args.force:
        print(f"Refusing to prune: swebench_pro/runner.py is running (pid {' '.join(running)}).", file=sys.stderr)
        print("Wait for it to finish, or pass --force.", file=sys.stderr)
        return 1

    if args.eval_dir is None:
        eval_dir = args.preds.parent.parent / "eval"
        eval_dir = eval_dir if eval_dir.is_dir() else None
    elif str(args.eval_dir) == "none":
        eval_dir = None
    else:
        eval_dir = args.eval_dir

    data = json.loads(args.preds.read_text())
    drop = {}
    for iid, entry in data.items():
        patch = entry.get("model_patch") or ""
        if is_real_patch(patch):
            continue
        if args.keep_empty and not patch.strip():
            continue
        drop[iid] = patch

    print(f"{len(data)} entries, {len(drop)} to drop, {len(data) - len(drop)} kept")
    for iid, patch in drop.items():
        reason = "empty patch" if not patch.strip() else patch.splitlines()[0][:110]
        print(f"  - {iid}\n      {reason}")

    if not drop:
        return 0
    if eval_dir is not None:
        stale = sum(1 for iid in drop if (eval_dir / iid).is_dir())
        print(f"{stale} stale eval result dir(s) under {eval_dir} will also be removed")
    if not args.apply:
        print("\nDry run. Re-run with --apply to rewrite preds.json.")
        return 0

    backup = args.preds.with_suffix(".json.bak")
    shutil.copy2(args.preds, backup)
    for iid in drop:
        del data[iid]
    args.preds.write_text(json.dumps(data, indent=2))
    print(f"\nBacked up to {backup}; wrote {len(data)} entries to {args.preds}")

    if eval_dir is not None:
        removed = 0
        for iid in drop:
            uid_dir = eval_dir / iid
            if uid_dir.is_dir():
                shutil.rmtree(uid_dir)
                removed += 1
        print(f"Removed {removed} stale eval result dir(s) under {eval_dir}")
    print("Re-run benchmarks/swebench_pro/run.sh with the same RUN_ID to retry the dropped instances.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
