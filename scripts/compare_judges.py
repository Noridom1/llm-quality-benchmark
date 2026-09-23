#!/usr/bin/env python3
"""Compare several LLM judges over one HLE run.

Reads the per-doc `judge_<slug>.jsonl` files written by judge_hle.py and reports
each judge's score plus pairwise agreement, so the headline number can be shown
with evidence that it does not depend on which judge produced it.

Scores are computed twice on purpose:

  * "all"    - every doc that judge graded; this is the judge's own score, and
               the main judge's "all" score is the number to report.
  * "common" - restricted to the docs EVERY judge graded. Judges differ in how
               many verdicts they fail to parse (a judge that burns its token
               budget reasoning returns nothing), so comparing raw scores across
               judges compares different denominators. Agreement figures use
               this set.

Agreement is raw agreement plus Cohen's kappa. Kappa matters because these
scores are far from 50/50: two judges that both mark ~60% of answers wrong
agree ~52% of the time by chance alone.
"""

import argparse
import json
import os
import re
import sys


def slug_of(model):
    return re.sub(r"[^A-Za-z0-9._-]", "__", model)


def load_judge(out_dir, model):
    """Return {(task, doc_id): bool} for docs this judge actually graded."""
    path = os.path.join(out_dir, f"judge_{slug_of(model)}.jsonl")
    if not os.path.exists(path):
        return None, path
    verdicts = {}
    with open(path) as fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            row = json.loads(line)
            # An unparsed verdict is an absent verdict, not a "no". Counting it
            # as wrong would silently penalise the model for the judge's failure.
            if not row.get("judge_parsed"):
                continue
            verdicts[(row["task"], row["doc_id"])] = bool(row["judge_correct"])
    return verdicts, path


def cohen_kappa(a, b, keys):
    n = len(keys)
    if n == 0:
        return float("nan")
    agree = sum(1 for k in keys if a[k] == b[k])
    po = agree / n
    pa_yes = sum(1 for k in keys if a[k]) / n
    pb_yes = sum(1 for k in keys if b[k]) / n
    pe = pa_yes * pb_yes + (1 - pa_yes) * (1 - pb_yes)
    if pe == 1.0:
        return float("nan")
    return (po - pe) / (1 - pe)


def pct(x, n):
    return f"{x}/{n} ({x / n:.1%})" if n else f"{x}/0 (n/a)"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dir", required=True, help="jobs/<RUN_ID>/hle-judged")
    ap.add_argument("--main-judge", required=True)
    ap.add_argument("--judge", action="append", default=[],
                    help="additional judge model (repeatable)")
    ap.add_argument("--self-judge", default="",
                    help="the model under test, if it also judged itself")
    ap.add_argument("--out", default="", help="write JSON here (default <dir>/judges_comparison.json)")
    args = ap.parse_args()

    order, seen = [], set()
    for m in [args.main_judge] + args.judge + ([args.self_judge] if args.self_judge else []):
        if m and m not in seen:
            seen.add(m)
            order.append(m)

    loaded, missing = {}, []
    for m in order:
        v, path = load_judge(args.dir, m)
        if v is None:
            missing.append((m, path))
        else:
            loaded[m] = v

    for m, path in missing:
        print(f"  note: no verdict file for {m} ({os.path.basename(path)}) -- skipping",
              file=sys.stderr)

    if args.main_judge not in loaded:
        print(f"ERROR: the main judge ({args.main_judge}) has no verdict file in {args.dir}",
              file=sys.stderr)
        return 2

    order = [m for m in order if m in loaded]
    common = set.intersection(*(set(v) for v in loaded.values()))

    print()
    print("=== Judge comparison ===")
    print(f"  Docs graded by every judge: {len(common)}")
    print()
    width = max(len(m) for m in order) + 2
    print(f"  {'judge':<{width}} {'role':<8} {'score (all graded)':<22} {'score (common set)'}")
    for m in order:
        v = loaded[m]
        role = ("main" if m == args.main_judge
                else "self" if m == args.self_judge else "second")
        n_all = len(v)
        c_all = sum(v.values())
        c_com = sum(1 for k in common if v[k])
        print(f"  {m:<{width}} {role:<8} {pct(c_all, n_all):<22} {pct(c_com, len(common))}")

    pairs = []
    if len(order) > 1:
        print()
        print("  pairwise agreement, on the common set:")
        for i, a in enumerate(order):
            for b in order[i + 1:]:
                va, vb = loaded[a], loaded[b]
                agree = sum(1 for k in common if va[k] == vb[k])
                kappa = cohen_kappa(va, vb, list(common))
                disagreed = sorted(k for k in common if va[k] != vb[k])
                print(f"    {a} vs {b}: {agree}/{len(common)} "
                      f"({agree / len(common):.1%})  kappa={kappa:.3f}" if common else "")
                if disagreed and len(disagreed) <= 10:
                    print(f"      disagreed on: "
                          + ", ".join(f"{t}#{d}" for t, d in disagreed))
                pairs.append({"a": a, "b": b, "agree": agree, "n": len(common),
                              "kappa": kappa,
                              "disagreed": [f"{t}#{d}" for t, d in disagreed]})

    main_all = sum(loaded[args.main_judge].values())
    main_n = len(loaded[args.main_judge])
    print()
    print(f"  HEADLINE (main judge {args.main_judge}): {pct(main_all, main_n)}")
    if args.self_judge and args.self_judge in loaded:
        print(f"  The {args.self_judge} row is a self-judge: it is a bias check on the")
        print("  headline, never a score to report.")

    result = {
        "main_judge": args.main_judge,
        "self_judge": args.self_judge or None,
        "common_docs": len(common),
        "judges": {
            m: {
                "role": ("main" if m == args.main_judge
                         else "self" if m == args.self_judge else "second"),
                "graded": len(loaded[m]),
                "correct_all": sum(loaded[m].values()),
                "correct_common": sum(1 for k in common if loaded[m][k]),
            } for m in order
        },
        "pairs": pairs,
        "headline": {"judge": args.main_judge, "correct": main_all, "graded": main_n,
                     "score": main_all / main_n if main_n else None},
    }
    out = args.out or os.path.join(args.dir, "judges_comparison.json")
    with open(out, "w") as fh:
        json.dump(result, fh, indent=2)
    print(f"  comparison: {out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
