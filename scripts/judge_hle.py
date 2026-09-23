#!/usr/bin/env python3
"""LLM-judge grading for a finished HLE run.

Why this exists
---------------
Upstream HLE (github.com/centerforaisafety/hle) does **not** grade exactMatch
answers with a string comparison; it asks a judge model whether the response's
final answer matches the reference answer. Our lm-eval task grades with
`exact_match`, so every answer that is right but formatted differently
(``\\(1+3x\\)`` vs ``$1 + 3x$``, ``Yes`` vs ``True``, an equivalent but
differently-written expression) scores 0. That makes the lm-eval number a
*floor*, not the benchmark's score.

This script re-grades an already-completed run from its logged samples, so it
needs no new answer generation -- only judge calls. Judge verdicts are cached in
sqlite keyed by (judge model, prompt), so re-running is free and the parsing can
be changed without re-spending tokens.

Reads:  jobs/<RUN_ID>/<dir>/<model>/samples_hle_*.jsonl  (needs --log_samples)
Writes: <out>/judge_<judge-model>.jsonl   per-doc verdicts
        <out>/judge_summary.json          aggregate + disagreement lists
"""

import argparse
import concurrent.futures as cf
import hashlib
import json
import os
import re
import sqlite3
import sys
import threading
import time

import requests

# Upstream prompt, verbatim from hle/judge.py (JUDGE_PROMPT). Keeping it
# byte-identical is the point: a locally-invented prompt would not be comparable
# to published HLE numbers.
JUDGE_PROMPT = """Judge whether the following [response] to [question] is correct or not based on the precise and unambiguous [correct_answer] below.

[question]: {question}

[response]: {response}

Your judgement must be in the format and criteria specified below:

extracted_final_answer: The final exact answer extracted from the [response]. Put the extracted answer as 'None' if there is no exact, final answer to extract from the response.

[correct_answer]: {correct_answer}

reasoning: Explain why the extracted_final_answer is correct or incorrect based on [correct_answer], focusing only on if there are meaningful differences between [correct_answer] and the extracted_final_answer. Do not comment on any background to the problem, do not attempt to solve the problem, do not argue for any answer different than [correct_answer], focus only on whether the answers match.

correct: Answer 'yes' if extracted_final_answer matches the [correct_answer] given above, or is within a small margin of error for numerical problems. Answer 'no' otherwise, i.e. if there if there is any inconsistency, ambiguity, non-equivalency, or if the extracted answer is incorrect.

confidence: The extracted confidence score between 0|\\%| and 100|\\%| from [response]. Put 100 if there is no confidence score available."""

# Upstream uses OpenAI structured outputs (a pydantic response_format) to get
# these four fields back. This endpoint is not guaranteed to support
# json_schema response_format, so we append an explicit envelope instruction and
# parse tolerantly. PROMPT_VERSION is part of the cache key: bump it whenever
# the text below changes, so stale verdicts are not reused.
JSON_ENVELOPE = """

Respond with ONLY a JSON object, no prose and no code fence, with exactly these keys:
{"extracted_final_answer": "...", "reasoning": "...", "correct": "yes" or "no", "confidence": 0-100}"""

PROMPT_VERSION = "hle-judge-v1"

# The 6 runaway samples in the extended run are 94k-190k chars of reasoning that
# never reached a final answer. Sending those whole would blow the judge's
# context for no benefit (the answer, if any, is at the end), so keep the head
# for context and the tail where the conclusion would be.
HEAD_CHARS = 1000


def clip_response(text, max_chars):
    if max_chars <= 0 or len(text) <= max_chars:
        return text, False
    tail = max_chars - HEAD_CHARS
    return (
        text[:HEAD_CHARS]
        + f"\n\n[... {len(text) - max_chars} characters of intermediate reasoning elided ...]\n\n"
        + text[-tail:],
        True,
    )


def parse_verdict(raw):
    """Extract the judge's fields. Returns (dict, ok)."""
    if not raw or not raw.strip():
        return {}, False
    # Preferred path: a JSON object somewhere in the reply.
    for match in re.finditer(r"\{.*\}", raw, re.DOTALL):
        for candidate in (match.group(0), match.group(0).replace("\n", " ")):
            try:
                obj = json.loads(candidate)
            except json.JSONDecodeError:
                continue
            if isinstance(obj, dict) and "correct" in obj:
                verdict = str(obj.get("correct", "")).strip().lower()
                if verdict.startswith(("yes", "true")):
                    return {
                        "correct": True,
                        "extracted": obj.get("extracted_final_answer"),
                        "reasoning": obj.get("reasoning"),
                        "confidence": obj.get("confidence"),
                    }, True
                if verdict.startswith(("no", "false")):
                    return {
                        "correct": False,
                        "extracted": obj.get("extracted_final_answer"),
                        "reasoning": obj.get("reasoning"),
                        "confidence": obj.get("confidence"),
                    }, True
    # Fallback: the field written as prose, e.g. `correct: no`.
    m = re.findall(r"correct\W{0,4}\s*(yes|no)\b", raw, re.IGNORECASE)
    if m:
        ok = m[-1].lower() == "yes"
        ex = re.search(r"extracted_final_answer\W{0,4}\s*(.+)", raw)
        return {
            "correct": ok,
            "extracted": ex.group(1).strip() if ex else None,
            "reasoning": None,
            "confidence": None,
        }, True
    return {}, False


# ---------------------------------------------------------------- judge client


def sse_completion(base_url, api_key, model, prompt, timeout, max_tokens, temperature):
    """One chat completion, consumed as a stream.

    Streaming is not an optimisation here: these are reasoning models, and a
    buffered request looks idle to the LB for the whole time-to-last-token and
    gets killed mid-CoT. Same reason tasks/lm-eval-streaming exists.
    """
    payload = {
        "model": model,
        "messages": [{"role": "user", "content": prompt}],
        "temperature": temperature,
        "max_tokens": max_tokens,
        "stream": True,
    }
    resp = requests.post(
        base_url,
        json=payload,
        headers={
            "Authorization": f"Bearer {api_key}",
            "Content-Type": "application/json",
            "Accept": "text/event-stream",
        },
        stream=True,
        timeout=timeout,
    )
    if not resp.ok:
        raise RuntimeError(f"HTTP {resp.status_code}: {resp.text[:400]}")
    content, reasoning, usage, finish = "", "", None, None
    for line in resp.iter_lines(decode_unicode=True):
        if not line or not line.startswith("data:"):
            continue
        data = line[5:].lstrip()
        if data == "[DONE]":
            break
        try:
            chunk = json.loads(data)
        except json.JSONDecodeError:
            continue
        if chunk.get("usage"):
            usage = chunk["usage"]
        for choice in chunk.get("choices") or []:
            delta = choice.get("delta") or {}
            if delta.get("content"):
                content += delta["content"]
            if delta.get("reasoning_content"):
                reasoning += delta["reasoning_content"]
            if choice.get("finish_reason"):
                finish = choice["finish_reason"]
    # Same fallback as the lm-eval patch: some replies arrive entirely in
    # reasoning_content with an empty content field. When that happens because
    # the token budget ran out mid-reasoning, the text holds no verdict -- the
    # caller escalates max_tokens rather than parsing the stump.
    return (content or reasoning), usage, finish


# ---------------------------------------------------------------------- cache


class VerdictCache:
    """sqlite cache of raw judge replies, keyed by (judge model, prompt).

    Raw text is stored rather than the parsed verdict so parse_verdict() can be
    fixed and re-applied without re-spending judge tokens.
    """

    def __init__(self, path):
        self.lock = threading.Lock()
        self.conn = sqlite3.connect(path, check_same_thread=False)
        self.conn.execute(
            "CREATE TABLE IF NOT EXISTS verdicts ("
            "key TEXT PRIMARY KEY, judge_model TEXT, task TEXT, doc_id INTEGER,"
            "raw TEXT, usage TEXT, ts REAL)"
        )
        self.conn.commit()

    @staticmethod
    def key(judge_model, prompt, tag=""):
        # tag is empty for the normal pass, so keys stay stable across versions
        # of this script; an escalated retry uses its own tag and its own row.
        parts = [PROMPT_VERSION, judge_model, prompt] + ([tag] if tag else [])
        return hashlib.sha256(json.dumps(parts).encode()).hexdigest()

    def get(self, key):
        with self.lock:
            row = self.conn.execute(
                "SELECT raw FROM verdicts WHERE key = ?", (key,)
            ).fetchone()
        return row[0] if row else None

    def put(self, key, judge_model, task, doc_id, raw, usage):
        with self.lock:
            self.conn.execute(
                "INSERT OR REPLACE INTO verdicts VALUES (?,?,?,?,?,?,?)",
                (
                    key,
                    judge_model,
                    task,
                    doc_id,
                    raw,
                    json.dumps(usage) if usage else None,
                    time.time(),
                ),
            )
            self.conn.commit()

    def count(self, judge_model=None):
        with self.lock:
            if judge_model:
                return self.conn.execute(
                    "SELECT COUNT(*) FROM verdicts WHERE judge_model = ?",
                    (judge_model,),
                ).fetchone()[0]
            return self.conn.execute("SELECT COUNT(*) FROM verdicts").fetchone()[0]


# ----------------------------------------------------------------------- main


# lm-eval logs one row per (doc, filter). The subtasks use different primary
# filter names -- `exact-match` for hle_exact_match, `custom-extract` for
# hle_multiple_choice -- so the primary is resolved per file instead of assumed.
FILTER_PREFERENCE = ("exact-match", "custom-extract", "flexible-extract")


def load_samples(path, primary_filter=None):
    """One record per doc, taking the primary filter's row.

    Returns (rows, filter_name). The response text is filter-independent, so the
    choice only affects which string-match baseline we compare the judge to.
    """
    by_filter = {}
    with open(path) as fh:
        for line in fh:
            row = json.loads(line)
            by_filter.setdefault(row.get("filter"), {})[row["doc_id"]] = row
    if not by_filter:
        return [], None
    order = ([primary_filter] if primary_filter else []) + list(FILTER_PREFERENCE)
    chosen = next((f for f in order if f in by_filter), sorted(by_filter)[0])
    docs = by_filter[chosen]
    return [docs[k] for k in sorted(docs)], chosen


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--samples", required=True, nargs="+", help="samples_*.jsonl")
    ap.add_argument("--out", required=True)
    ap.add_argument("--judge-model", required=True)
    ap.add_argument("--cache", required=True)
    ap.add_argument(
        "--primary-filter",
        default=None,
        help="filter row to use as the string-match baseline; auto-detected per file",
    )
    ap.add_argument("--concurrency", type=int, default=6)
    ap.add_argument("--timeout", type=float, default=900)
    ap.add_argument("--max-tokens", type=int, default=4096)
    ap.add_argument(
        "--escalate-max-tokens",
        type=int,
        default=16384,
        help="on an unparseable reply, retry once with this token budget",
    )
    ap.add_argument("--temperature", type=float, default=0.0)
    ap.add_argument("--max-resp-chars", type=int, default=24000)
    ap.add_argument("--limit", type=int, default=0)
    ap.add_argument("--retries", type=int, default=3)
    ap.add_argument(
        "--offline",
        action="store_true",
        help="score from cached verdicts only; never call the judge",
    )
    args = ap.parse_args()

    base_url = os.environ["OPENAI_BASE_URL"].rstrip("/")
    if not base_url.endswith("/chat/completions"):
        base_url += "/chat/completions"
    api_key = os.environ.get("API_KEY") or os.environ["OPENAI_API_KEY"]

    os.makedirs(args.out, exist_ok=True)
    cache = VerdictCache(args.cache)

    jobs = []
    filters_used = {}
    for path in args.samples:
        task = re.search(r"samples_(hle_\w+?)_\d{4}-", os.path.basename(path))
        task = task.group(1) if task else os.path.basename(path)
        rows, used_filter = load_samples(path, args.primary_filter)
        if not rows:
            print(f"  note: no rows in {path} -- skipping", flush=True)
            continue
        filters_used[task] = used_filter
        if args.limit:
            rows = rows[: args.limit]
        for row in rows:
            response, clipped = clip_response(
                row["resps"][0][0], args.max_resp_chars
            )
            prompt = (
                JUDGE_PROMPT.format(
                    question=row["doc"]["question"],
                    response=response,
                    correct_answer=row["target"],
                )
                + JSON_ENVELOPE
            )
            jobs.append(
                {
                    "task": task,
                    "doc_id": row["doc_id"],
                    "hle_id": row["doc"].get("id"),
                    "category": row["doc"].get("category"),
                    "target": row["target"],
                    "string_match": float(row.get("exact_match", 0.0)) == 1.0,
                    "string_extracted": row["filtered_resps"][0],
                    "response_clipped": clipped,
                    "prompt": prompt,
                    "key": VerdictCache.key(args.judge_model, prompt),
                }
            )

    cached = sum(1 for j in jobs if cache.get(j["key"]) is not None)
    print(
        f"  jobs: {len(jobs)}   cached: {cached}   to call: {len(jobs) - cached}",
        flush=True,
    )
    if args.offline and cached < len(jobs):
        print("  --offline: missing verdicts will be reported as unjudged", flush=True)

    done = [0]
    done_lock = threading.Lock()

    def fetch(job, max_tokens, tag):
        """Cached judge call. Returns (raw_text, error, finish_reason)."""
        key = VerdictCache.key(args.judge_model, job["prompt"], tag)
        raw = cache.get(key)
        if raw is not None:
            return raw, None, "cached"
        if args.offline:
            return None, "no cached verdict (--offline)", None
        last = None
        for attempt in range(args.retries):
            try:
                raw, usage, finish = sse_completion(
                    base_url,
                    api_key,
                    args.judge_model,
                    job["prompt"],
                    args.timeout,
                    max_tokens,
                    args.temperature,
                )
                if raw and raw.strip():
                    cache.put(
                        key,
                        args.judge_model,
                        job["task"],
                        job["doc_id"],
                        raw,
                        usage,
                    )
                    return raw, None, finish
                last = "empty response"
            except Exception as exc:  # noqa: BLE001 - report, don't abort the sweep
                last = f"{type(exc).__name__}: {exc}"
            time.sleep(2 * (attempt + 1))
        return None, last, None

    def run(job):
        raw, error, finish = fetch(job, args.max_tokens, "")
        verdict, ok = parse_verdict(raw) if raw else ({}, False)
        escalated = False
        # A reasoning judge can burn its whole token budget on the CoT and never
        # emit the verdict, leaving an unparseable stump. Retry once with a much
        # larger budget instead of silently recording "unjudged".
        if not ok and args.escalate_max_tokens > args.max_tokens:
            raw2, error2, finish2 = fetch(
                job, args.escalate_max_tokens, f"maxtok{args.escalate_max_tokens}"
            )
            verdict2, ok2 = parse_verdict(raw2) if raw2 else ({}, False)
            if ok2:
                raw, error, finish, verdict, ok = raw2, error2, finish2, verdict2, ok2
                escalated = True
            elif raw2:
                raw, finish = raw2, finish2
        job["judge_raw_len"] = len(raw) if raw else 0
        job["judge_finish_reason"] = finish
        job["judge_escalated"] = escalated
        job["judge_parsed"] = ok
        job["judge_correct"] = verdict.get("correct") if ok else None
        job["judge_extracted"] = verdict.get("extracted") if ok else None
        job["judge_reasoning"] = verdict.get("reasoning") if ok else None
        job["judge_confidence"] = verdict.get("confidence") if ok else None
        if error and not ok:
            job["error"] = error
        elif raw and not ok:
            job["error"] = "unparseable judge reply"
            job["judge_raw_head"] = raw[:400]
        with done_lock:
            done[0] += 1
            if done[0] % 10 == 0 or done[0] == len(jobs):
                print(f"  {done[0]}/{len(jobs)}", flush=True)
        return job

    t0 = time.time()
    with cf.ThreadPoolExecutor(max_workers=args.concurrency) as pool:
        results = list(pool.map(run, jobs))
    elapsed = time.time() - t0

    slug = re.sub(r"[^A-Za-z0-9._-]", "__", args.judge_model)
    detail_path = os.path.join(args.out, f"judge_{slug}.jsonl")
    with open(detail_path, "w") as fh:
        for job in results:
            record = {k: v for k, v in job.items() if k != "prompt"}
            fh.write(json.dumps(record, ensure_ascii=False) + "\n")

    summary = {
        "judge_model": args.judge_model,
        "prompt_version": PROMPT_VERSION,
        "primary_filter_per_task": filters_used,
        "max_resp_chars": args.max_resp_chars,
        "judge_gen_kwargs": {
            "temperature": args.temperature,
            "max_tokens": args.max_tokens,
            "escalate_max_tokens": args.escalate_max_tokens,
        },
        "elapsed_seconds": round(elapsed, 1),
        "judge_calls_made": len(jobs) - cached,
        "verdicts_from_cache": cached,
        "tasks": {},
    }
    for task in sorted({j["task"] for j in results}):
        group = [j for j in results if j["task"] == task]
        judged = [j for j in group if j["judge_correct"] is not None]
        unjudged = [j for j in group if j["judge_correct"] is None]
        judge_ok = [j for j in judged if j["judge_correct"]]
        string_ok = [j for j in group if j["string_match"]]
        gained = sorted(
            j["doc_id"] for j in judged if j["judge_correct"] and not j["string_match"]
        )
        lost = sorted(
            j["doc_id"] for j in judged if j["string_match"] and not j["judge_correct"]
        )
        n = len(group)
        summary["tasks"][task] = {
            "n": n,
            "string_match_filter": filters_used.get(task),
            "string_match_correct": len(string_ok),
            "string_match_score": round(len(string_ok) / n, 4) if n else None,
            "judge_correct": len(judge_ok),
            "judge_score_over_all": round(len(judge_ok) / n, 4) if n else None,
            "judged": len(judged),
            "unjudged": len(unjudged),
            "unjudged_doc_ids": sorted(j["doc_id"] for j in unjudged),
            "judge_score_over_judged": round(len(judge_ok) / len(judged), 4)
            if judged
            else None,
            "gained_vs_string_match": gained,
            "lost_vs_string_match": lost,
            "escalated_doc_ids": sorted(
                j["doc_id"] for j in group if j.get("judge_escalated")
            ),
            "clipped_responses": sorted(
                j["doc_id"] for j in group if j["response_clipped"]
            ),
        }
    # Per-judge filename: a second judge's run must not overwrite the first's
    # summary, since comparing two judges is the point of running two.
    summary_path = os.path.join(args.out, f"judge_summary_{slug}.json")
    with open(summary_path, "w") as fh:
        json.dump(summary, fh, indent=2)

    print()
    print(f"  judge={args.judge_model}  elapsed={elapsed:.1f}s")
    for task, s in summary["tasks"].items():
        print(
            f"  {task}: string-match {s['string_match_correct']}/{s['n']} "
            f"({s['string_match_score']:.3f})  ->  judge {s['judge_correct']}/{s['n']} "
            f"({s['judge_score_over_all']:.3f})   +{len(s['gained_vs_string_match'])} "
            f"-{len(s['lost_vs_string_match'])}  unjudged={s['unjudged']}"
        )
    print(f"  detail : {detail_path}")
    print(f"  summary: {summary_path}")
    errors = [j for j in results if j.get("error")]
    if errors:
        print(f"  WARNING: {len(errors)} judge errors, e.g. {errors[0]['error'][:200]}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
