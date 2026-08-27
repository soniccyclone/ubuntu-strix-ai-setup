#!/usr/bin/env python3
"""Fire N concurrent completions at a llama-server and report both numbers.

Per-stream tok/s is what one user feels and it FALLS with concurrency.
Aggregate tok/s is what the machine delivers and it should RISE. Reporting only
one of them is how a scaling claim becomes meaningless, so this reports both
plus the MTP acceptance rate, without which a speculation number says nothing.
"""
import json, sys, time, urllib.request
from concurrent.futures import ThreadPoolExecutor

PORT = int(sys.argv[1]); N = int(sys.argv[2]); MAXTOK = int(sys.argv[3])

PROMPTS = [
    "Explain how a page fault is serviced on x86-64, from the CPU fault to the process resuming.",
    "Write a C function inserting a node into a red-black tree, with the rebalancing cases.",
    "Compare magnetic drum memory with modern DRAM: access model, latency, cost per bit.",
    "Describe how a TCP three-way handshake establishes a connection, including sequence numbers.",
]

def one(i):
    body = json.dumps({
        "messages": [{"role": "user", "content": PROMPTS[i % len(PROMPTS)]}],
        "max_tokens": MAXTOK, "temperature": 0, "top_p": 1.0, "top_k": 0,
        "stream": False,
    }).encode()
    req = urllib.request.Request(f"http://127.0.0.1:{PORT}/v1/chat/completions",
                                data=body, headers={"Content-Type": "application/json"})
    t0 = time.time()
    with urllib.request.urlopen(req, timeout=900) as r:
        d = json.loads(r.read())
    t = d.get("timings", {})
    return {
        "wall": time.time() - t0,
        "n": t.get("predicted_n", 0),
        "ms": t.get("predicted_ms", 0.0),
        "tps": t.get("predicted_per_second", 0.0),
        "draft_n": t.get("draft_n", 0),
        "draft_acc": t.get("draft_n_accepted", 0),
    }

# Warm one slot first so graph build is not charged to the measured window.
one(0)

t0 = time.time()
with ThreadPoolExecutor(max_workers=N) as ex:
    res = list(ex.map(one, range(N)))
wall = time.time() - t0

tok = sum(r["n"] for r in res)
per = [r["tps"] for r in res if r["tps"]]
dn = sum(r["draft_n"] for r in res); da = sum(r["draft_acc"] for r in res)
print(json.dumps({
    "streams": N,
    "aggregate_tps": round(tok / wall, 2) if wall else 0,
    "per_stream_tps_mean": round(sum(per) / len(per), 2) if per else 0,
    "per_stream_tps_min": round(min(per), 2) if per else 0,
    "tokens": tok,
    "wall_s": round(wall, 2),
    "draft_n": dn,
    "draft_accept_pct": round(100 * da / dn, 1) if dn else None,
}))
