#!/usr/bin/env python3
"""Time a ComfyUI workflow, cold and then warm, against a running server.

The warm number is the point. Every published figure for this hardware is a
single cold run, so nobody has separated "the model is slow" from "the weights
are being reloaded". Running the same graph twice separates them.
"""
import json, sys, time, urllib.request, uuid, argparse

def post(host, path, obj):
    r = urllib.request.Request(f"http://{host}{path}",
                               data=json.dumps(obj).encode(),
                               headers={"Content-Type": "application/json"})
    return json.loads(urllib.request.urlopen(r).read())

def get(host, path):
    return json.loads(urllib.request.urlopen(f"http://{host}{path}").read())

def reseed(graph, n):
    """ComfyUI caches by graph hash: an identical graph returns the previous
    result in ~1 s without executing anything. Every run must differ in seed or
    the warm number measures the cache, not the model."""
    hits = 0
    for node in graph.values():
        for k in ("seed", "noise_seed"):
            if k in node.get("inputs", {}) and isinstance(node["inputs"][k], (int, float)):
                node["inputs"][k] = 100000 + n; hits += 1
    return hits

def run_once(host, graph):
    cid = str(uuid.uuid4())
    t0 = time.time()
    pid = post(host, "/prompt", {"prompt": graph, "client_id": cid})["prompt_id"]
    while True:
        h = get(host, f"/history/{pid}")
        if pid in h:
            st = h[pid].get("status", {})
            if st.get("completed") or st.get("status_str") == "success":
                return time.time() - t0, None
            if st.get("status_str") == "error":
                return time.time() - t0, json.dumps(st)[:400]
        time.sleep(1)

def patch(graph, subs):
    n = 0
    for node in graph.values():
        for k, v in node.get("inputs", {}).items():
            if isinstance(v, str) and v in subs:
                node["inputs"][k] = subs[v]; n += 1
    return n

ap = argparse.ArgumentParser()
ap.add_argument("workflow")
ap.add_argument("--host", default="127.0.0.1:8188")
ap.add_argument("--runs", type=int, default=2)
ap.add_argument("--sub", action="append", default=[], help="old=new filename")
a = ap.parse_args()

graph = json.load(open(a.workflow))
subs = dict(s.split("=", 1) for s in a.sub)
if subs:
    print(f"patched {patch(graph, subs)} filename references")

for i in range(a.runs):
    if i == 0 and not reseed(dict(graph), 0):
        print("warning: no seed input found; warm runs may hit the result cache")
    reseed(graph, i)
    dt, err = run_once(a.host, graph)
    label = "cold" if i == 0 else f"warm{i}"
    print(f"{label:<6} {dt:8.1f} s" + (f"   ERROR {err}" if err else ""), flush=True)
