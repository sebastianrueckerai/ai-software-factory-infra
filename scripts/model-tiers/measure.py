#!/usr/bin/env python3
"""Measures model candidates through LiteLLM on three fixed samples and ranks them per tier.

  measure.py run --base URL --out FILE [--runs 3] [--only NAME ...]
      Calls every candidate of candidates.json RUNS times per sample through
      LiteLLM's /v1/chat/completions with the key in $LITELLM_KEY and appends
      one JSON line per call to FILE (a rerun skips calls already recorded).
  measure.py table FILE
      Checks every recorded answer and prints one markdown table per tier.

The samples are factoryd's own tasks: a coding fix (the answer's lru.go must
pass lru_test.go, run by `go test` in a golang container without network),
a model review of a diff with a planted defect (verdict concerns and a
finding naming the unsigned-request bypass) and a supervisor judgement of a
stuck session (action redirect, guidance naming parse.go). The review and
supervisor prompts are factoryd's (samples/*-prompt.txt, copied from
internal/factoryd gates.go and supervisor.go).

Ranking inside a tier: passes (of 3 samples x runs) descending, then p50
latency, then cost per call. A candidate with at least 7 of 9 passes is
eligible; eligible ones get weight n..1 by rank.
"""
import argparse
import functools
import json
import os
import re
import statistics
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
SAMPLES = os.path.join(HERE, "samples")
SAMPLE_NAMES = ("coding", "review", "supervisor")
TIERS = ("high", "mid", "low")
MAX_TOKENS = 16384
TIMEOUT_S = 360
GO_IMAGE = "golang:1.24-alpine"
ELIGIBLE_PASSES = 7


def read(name):
    with open(os.path.join(SAMPLES, name)) as f:
        return f.read()


def candidates():
    with open(os.path.join(HERE, "candidates.json")) as f:
        return json.load(f)


def messages(sample):
    if sample == "coding":
        return [
            {"role": "system", "content": "You fix Go code. Answer with the complete corrected file in one ```go fenced block and nothing else."},
            {"role": "user", "content": "Package lru has a failing test. Fix lru.go so every test passes; do not change the tests.\n\n"
             "lru.go:\n```go\n" + read("lru.go") + "```\n\nlru_test.go:\n```go\n" + read("lru_test.go") + "```\n\n"
             "go test ./... prints:\n```\n--- FAIL: TestGetMakesAnEntryRecent (0.00s)\n"
             "    lru_test.go:27: b survived; after Get(a) it was the least recently used\nFAIL\nFAIL\tlru\t0.001s\n```"},
        ], False
    prompt = read(sample + "-prompt.txt")
    with open(os.path.join(SAMPLES, sample + ".json")) as f:
        user = json.dumps(json.load(f), indent=1)
    return [{"role": "system", "content": prompt}, {"role": "user", "content": user}], True


def call(base, key, model, sample):
    msgs, json_mode = messages(sample)
    body = {"model": model, "max_tokens": MAX_TOKENS, "messages": msgs}
    if json_mode:
        body["response_format"] = {"type": "json_object"}
    req = urllib.request.Request(base.rstrip("/") + "/v1/chat/completions", data=json.dumps(body).encode(),
                                 headers={"Authorization": "Bearer " + key, "Content-Type": "application/json"})
    rec = {"candidate": model, "sample": sample}
    start = time.monotonic()
    try:
        with urllib.request.urlopen(req, timeout=TIMEOUT_S) as res:
            status, headers, raw = res.status, res.headers, res.read()
    except urllib.error.HTTPError as e:
        status, headers, raw = e.code, e.headers, e.read()
    except Exception as e:  # noqa: BLE001 -- a timeout or a reset is a recorded failure, not a crash
        rec.update(latency_s=time.monotonic() - start, status=0, error=str(e)[:500])
        return rec
    rec.update(latency_s=round(time.monotonic() - start, 3), status=status,
               deployment=headers.get("x-litellm-model-name", ""))
    cost = headers.get("x-litellm-response-cost")
    rec["cost_usd"] = float(cost) if cost not in (None, "", "None") else None
    try:
        doc = json.loads(raw)
    except ValueError:
        rec["error"] = raw[:500].decode(errors="replace")
        return rec
    if status != 200:
        rec["error"] = json.dumps(doc.get("error", doc))[:500]
        return rec
    choice = doc["choices"][0]
    rec.update(content=choice["message"].get("content") or "", finish_reason=choice.get("finish_reason"),
               usage={k: doc.get("usage", {}).get(k) for k in ("prompt_tokens", "completion_tokens")})
    return rec


def run(args):
    key = os.environ.get("LITELLM_KEY")
    if not key:
        sys.exit("LITELLM_KEY is not set")
    done = {}
    if os.path.exists(args.out):
        with open(args.out) as f:
            for line in f:
                r = json.loads(line)
                done[(r["candidate"], r["sample"])] = done.get((r["candidate"], r["sample"]), 0) + 1
    with open(args.out, "a") as out:
        for c in candidates():
            if args.only and c["model_name"] not in args.only:
                continue
            for sample in SAMPLE_NAMES:
                for _ in range(args.runs - done.get((c["model_name"], sample), 0)):
                    rec = call(args.base, key, c["model_name"], sample)
                    out.write(json.dumps(rec) + "\n")
                    out.flush()
                    print(f'{c["model_name"]} {sample}: {rec["status"]} {rec.get("latency_s")}s {rec.get("cost_usd")} {check(rec)}', flush=True)


def fenced(text, lang):
    m = re.search(r"```" + lang + r"\s*\n(.*?)```", text, re.S)
    if m:
        return m.group(1)
    m = re.search(r"```\w*\s*\n(.*?)```", text, re.S)
    return m.group(1) if m else text


def answer_json(text):
    s = text.strip()
    if s.startswith("```"):
        s = fenced(s, "json")
    return json.loads(s)


@functools.lru_cache(maxsize=None)
def check_coding(content):
    src = fenced(content, "go")
    if "package lru" not in src:
        return False
    with tempfile.TemporaryDirectory() as d:
        for name, text in (("lru.go", src), ("lru_test.go", read("lru_test.go")), ("go.mod", "module lru\n\ngo 1.22\n")):
            with open(os.path.join(d, name), "w") as f:
                f.write(text)
        # the answer is untrusted code: no network, a throwaway container
        r = subprocess.run(["docker", "run", "--rm", "--network", "none", "-v", d + ":/src", "-w", "/src", GO_IMAGE,
                            "go", "test", "./..."], capture_output=True, timeout=180)
        return r.returncode == 0


def check_review(content):
    try:
        v = answer_json(content)
    except ValueError:
        return False
    if not isinstance(v, dict) or v.get("verdict") != "concerns" or not isinstance(v.get("findings"), list):
        return False
    return any(isinstance(f, str) and re.search(r"sign|unsigned|X-Factory-Signature", f, re.I) for f in v["findings"])


def check_supervisor(content):
    try:
        v = answer_json(content)
    except ValueError:
        return False
    return isinstance(v, dict) and v.get("action") == "redirect" and "parse.go" in str(v.get("guidance", ""))


CHECKS = {"coding": check_coding, "review": check_review, "supervisor": check_supervisor}


def check(rec):
    if rec.get("status") != 200 or not rec.get("content"):
        return False
    return CHECKS[rec["sample"]](rec["content"])


def rank(records, cands):
    rows = {c["model_name"]: {**c, "passes": {s: 0 for s in SAMPLE_NAMES}, "calls": 0, "latencies": [], "costs": [],
                              "deployments": set(), "errors": 0} for c in cands}
    for rec in records:
        r = rows.get(rec["candidate"])
        if r is None:
            continue
        r["calls"] += 1
        if rec.get("status") != 200:
            r["errors"] += 1
            continue
        r["latencies"].append(rec["latency_s"])
        if rec.get("cost_usd") is not None:
            r["costs"].append(rec["cost_usd"])
        if rec.get("deployment"):
            r["deployments"].add(rec["deployment"])
        if check(rec):
            r["passes"][rec["sample"]] += 1
    tiers = {}
    for r in rows.values():
        r["total"] = sum(r["passes"].values())
        r["p50"] = statistics.median(r["latencies"]) if r["latencies"] else None
        r["cost"] = statistics.fmean(r["costs"]) if r["costs"] else None
        tiers.setdefault(r["tier"], []).append(r)
    inf = float("inf")
    for t in tiers.values():
        t.sort(key=lambda r: (-r["total"], r["p50"] if r["p50"] is not None else inf, r["cost"] if r["cost"] is not None else inf))
        eligible = [r for r in t if r["total"] >= ELIGIBLE_PASSES]
        for i, r in enumerate(t):
            r["rank"] = i + 1
            r["weight"] = len(eligible) - eligible.index(r) if r in eligible else 0
    return tiers


def table(records, cands, runs=3):
    out = []
    tiers = rank(records, cands)
    for tier in TIERS:
        if tier not in tiers:
            continue
        out.append(f"### tier-{tier}\n")
        out.append(f"| rank | candidate | deployment | coding | review | supervisor | passes | p50 s | USD per call | errors | weight |")
        out.append("|---|---|---|---|---|---|---|---|---|---|---|")
        for r in tiers[tier]:
            p = r["passes"]
            out.append("| {} | {} | {} | {}/{} | {}/{} | {}/{} | {}/{} | {} | {} | {} | {} |".format(
                r["rank"], r["model_name"], ", ".join(sorted(r["deployments"])) or r["model"],
                p["coding"], runs, p["review"], runs, p["supervisor"], runs, r["total"], runs * len(SAMPLE_NAMES),
                f'{r["p50"]:.1f}' if r["p50"] is not None else "-",
                f'{r["cost"]:.6f}' if r["cost"] is not None else "-", r["errors"], r["weight"]))
        out.append("")
    return "\n".join(out)


def load(path):
    with open(path) as f:
        return [json.loads(line) for line in f if line.strip()]


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    r = sub.add_parser("run")
    r.add_argument("--base", required=True)
    r.add_argument("--out", required=True)
    r.add_argument("--runs", type=int, default=3)
    r.add_argument("--only", nargs="*")
    t = sub.add_parser("table")
    t.add_argument("file")
    args = ap.parse_args()
    if args.cmd == "run":
        run(args)
    else:
        print(table(load(args.file), candidates()))


if __name__ == "__main__":
    main()
