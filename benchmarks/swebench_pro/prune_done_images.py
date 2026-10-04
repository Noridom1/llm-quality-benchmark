#!/usr/bin/env python3
"""Free docker disk by removing sweap images whose instance is already done.

Safe to run mid-flight, unlike a blanket `docker rmi`. An instance's image is
only pulled while that instance is in flight, i.e. strictly before its
preds.json entry exists. So an image whose every instance already has a preds
entry can never be the target of a concurrent `docker run` pull -- which is
exactly the race that a blanket prune loses.

Note tags are truncated to docker's 128-char limit, so two instances can share
one tag; a tag is only removed when *all* of its instances are done.

That argument only holds during Phase 1. In Phase 2 the eval re-pulls images
for instances that already have a preds entry, so "done in preds" no longer
means "nobody is pulling it". Pass --eval-dir to additionally require an
eval output file per instance; use it whenever Phase 2 may be running.

Pruning costs bandwidth (a later phase re-pulls), never correctness.
"""

import argparse
import json
import subprocess
import sys
from pathlib import Path

import yaml


def docker(*args: str) -> str:
    return subprocess.run(["docker", *args], capture_output=True, text=True).stdout


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--preds", type=Path, required=True)
    ap.add_argument("--instances", type=Path, required=True)
    ap.add_argument("--apply", action="store_true", help="actually remove (default: dry run)")
    ap.add_argument(
        "--eval-dir",
        type=Path,
        default=None,
        help="also require an eval <uid>/*_output.json per instance before removing "
        "its image (required for safety while Phase 2 is running)",
    )
    args = ap.parse_args()

    insts = yaml.safe_load(args.instances.read_text())
    if isinstance(insts, dict):
        insts = insts.get("instances", insts)
    done = set(json.loads(args.preds.read_text()))

    # tag -> instance ids that map to it (truncation can collide)
    tags: dict[str, set[str]] = {}
    for i in insts:
        image = i.get("image_name")
        if image:
            tags.setdefault(image, set()).add(i["instance_id"])

    in_use = set(docker("ps", "--format", "{{.Image}}").split())
    local = set(docker("images", "--format", "{{.Repository}}:{{.Tag}}").split())

    if args.eval_dir is not None:
        # An instance is only safe once Phase 2 has written its result, because
        # until then the eval may still be pulling that very image.
        evaluated = {d.name for d in args.eval_dir.glob("*") if any(d.glob("*_output.json"))}
        done &= evaluated

    prunable = [
        tag for tag, ids in tags.items()
        if tag in local and tag not in in_use and ids <= done
    ]

    scope = "done+evaluated" if args.eval_dir is not None else "done"
    print(f"{len(local)} local images, {len(done)} instances {scope}, {len(prunable)} prunable")
    if not args.apply:
        for tag in prunable[:10]:
            print("  would remove", tag)
        print("(dry run; pass --apply to remove)")
        return 0

    removed = 0
    for tag in prunable:
        # Re-check: docker refuses images backing a container, so a lost race
        # here fails harmlessly instead of corrupting a running container.
        if subprocess.run(["docker", "rmi", tag], capture_output=True).returncode == 0:
            removed += 1
    print(f"Removed {removed}/{len(prunable)} images")
    return 0


if __name__ == "__main__":
    sys.exit(main())
