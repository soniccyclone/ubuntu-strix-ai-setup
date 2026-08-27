#!/usr/bin/env python3
"""Measure a llama-server under N concurrent requests.

Reports two throughput figures because they move in opposite directions and a
scaling claim that does not say which it means is unreadable:

  per-stream  what one caller experiences. Falls as concurrency rises.
  aggregate   what the machine delivers. Rises as concurrency rises.

Aggregate is total tokens over the wall time of the whole batch. Summing the
per-request rates instead would double-count overlapped time and report a
speedup that did not happen.

Draft acceptance travels with every measurement. A speculation result without an
acceptance rate does not say whether speculation happened at all.

Usage:
  concbench.py --port 8080 --streams 4 --reps 5 [--workload humaneval|prose]
               [--tasks path/to/humaneval.jsonl] [--maxtok 512]
"""
import argparse
import json
import statistics
import sys
import time
import urllib.error
import urllib.request
from concurrent.futures import ThreadPoolExecutor

# Discursive prose. Kept distinct from the code workload on purpose: the
# operations guide records acceptance at ~76% on code and 46-47% on prose, and
# speculation's value rides on acceptance. Mixing them produces a number that
# belongs to neither regime.
PROSE = [
    "Explain how a page fault is serviced on x86-64, from the CPU fault through "
    "to the process resuming.",
    "Compare magnetic drum memory with modern DRAM: access model, latency, cost "
    "per bit, and why the industry moved.",
    "Describe how a TCP three-way handshake establishes a connection, including "
    "what each sequence number is for.",
    "Explain why a garbage collector's pause time and its throughput are in "
    "tension, and what generational collection buys.",
]

HUMANEVAL_INSTRUCTION = (
    "Complete the following Python function. Reply with the full function "
    "implementation in a single ```python code block.\n\n"
)


def load_prompts(workload, tasks_path):
    if workload == "prose":
        return list(PROSE)
    if not tasks_path:
        sys.exit("--workload humaneval needs --tasks pointing at humaneval.jsonl")
    out = []
    with open(tasks_path) as fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            out.append(HUMANEVAL_INSTRUCTION + json.loads(line)["prompt"])
    if not out:
        sys.exit(f"no tasks in {tasks_path}")
    return out


def one_request(port, prompt, maxtok):
    body = json.dumps({
        "messages": [{"role": "user", "content": prompt}],
        "max_tokens": maxtok,
        # Greedy, matching the conditions the published figure was taken under.
        # Anything else measures a different thing.
        "temperature": 0, "top_p": 1.0, "top_k": 0,
        "stream": False,
    }).encode()
    req = urllib.request.Request(
        f"http://127.0.0.1:{port}/v1/chat/completions",
        data=body, headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=1800) as resp:
        d = json.loads(resp.read())
    t = d.get("timings", {})
    return {
        "n": t.get("predicted_n", 0),
        "tps": t.get("predicted_per_second", 0.0),
        "draft_n": t.get("draft_n", 0),
        "draft_acc": t.get("draft_n_accepted", 0),
    }


def batch(port, prompts, streams, maxtok, offset):
    """One batch of `streams` concurrent requests. Returns the batch's figures."""
    picks = [prompts[(offset + i) % len(prompts)] for i in range(streams)]
    t0 = time.time()
    with ThreadPoolExecutor(max_workers=streams) as ex:
        res = list(ex.map(lambda p: one_request(port, p, maxtok), picks))
    wall = time.time() - t0
    tok = sum(r["n"] for r in res)
    per = [r["tps"] for r in res if r["tps"]]
    return {
        "aggregate": tok / wall if wall else 0.0,
        "per_stream": statistics.mean(per) if per else 0.0,
        "tokens": tok,
        "wall": wall,
        "draft_n": sum(r["draft_n"] for r in res),
        "draft_acc": sum(r["draft_acc"] for r in res),
    }


def spread(values):
    """Peak-to-peak as a percentage of the mean.

    Reported rather than a standard deviation because the question this answers
    is "could these two arms be the same number", and the measured noise floor
    on this machine is 13% peak-to-peak.
    """
    if not values:
        return 0.0
    m = statistics.mean(values)
    return 100.0 * (max(values) - min(values)) / m if m else 0.0


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, required=True)
    ap.add_argument("--streams", type=int, required=True)
    ap.add_argument("--reps", type=int, default=5)
    ap.add_argument("--maxtok", type=int, default=512)
    ap.add_argument("--workload", choices=("humaneval", "prose"), default="humaneval")
    ap.add_argument("--tasks")
    ap.add_argument("--warm", type=int, default=1,
                    help="batches to run and discard before measuring")
    args = ap.parse_args()

    if args.reps < 5:
        # The noise floor here is larger than the effects being measured.
        # Anything below five repeats is not a measurement.
        print(f"warning: --reps {args.reps} is below the floor of 5", file=sys.stderr)

    prompts = load_prompts(args.workload, args.tasks)

    for i in range(args.warm):
        batch(args.port, prompts, args.streams, args.maxtok, i)

    runs = [batch(args.port, prompts, args.streams, args.maxtok, r)
            for r in range(args.reps)]

    agg = [r["aggregate"] for r in runs]
    per = [r["per_stream"] for r in runs]
    dn = sum(r["draft_n"] for r in runs)
    da = sum(r["draft_acc"] for r in runs)

    print(json.dumps({
        "streams": args.streams,
        "reps": args.reps,
        "workload": args.workload,
        "aggregate_tps": round(statistics.mean(agg), 2),
        "aggregate_spread_pct": round(spread(agg), 1),
        "per_stream_tps": round(statistics.mean(per), 2),
        "per_stream_spread_pct": round(spread(per), 1),
        "tokens_total": sum(r["tokens"] for r in runs),
        "draft_n": dn,
        "draft_accept_pct": round(100.0 * da / dn, 1) if dn else None,
    }))


if __name__ == "__main__":
    main()
