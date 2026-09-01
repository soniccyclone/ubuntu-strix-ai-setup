#!/usr/bin/env python3
"""HumanEval pass@1 against a llama-server, with generated code sandboxed.

Throughput says nothing about whether a quantisation broke the model. This
generates a completion per task, executes it against the task's own test
harness, and reports the pass rate.

**Generated code is never executed on the host.** Each candidate runs in a
throwaway container with no network and no mounts, fed on stdin, with a wall
clock limit. A model asked to write code will occasionally write code that
deletes things or hangs, and that is not a reason to trust it with a shell.

Usage:
  humaneval_score.py --port 8080 --tasks humaneval.jsonl [--limit N] [--maxtok 640]
"""
import argparse
import json
import re
import subprocess
import sys
import urllib.request

INSTR = ("Complete the following Python function. Reply with the full function "
         "implementation in a single ```python code block.\n\n")


def generate(port, prompt, maxtok):
    body = json.dumps({
        "messages": [{"role": "user", "content": INSTR + prompt}],
        "max_tokens": maxtok, "temperature": 0, "top_p": 1.0, "top_k": 0,
        "stream": False,
    }).encode()
    req = urllib.request.Request(f"http://127.0.0.1:{port}/v1/chat/completions",
                                 data=body, headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=900) as r:
        return json.loads(r.read())["choices"][0]["message"].get("content") or ""


def extract(text):
    m = re.search(r"```(?:python)?\s*\n(.*?)```", text, re.S)
    return m.group(1) if m else text


def run_sandboxed(source, timeout=25):
    """Execute in a container with no network and no mounts. Never on the host."""
    try:
        p = subprocess.run(
            ["podman", "run", "--rm", "-i", "--network=none",
             "--memory=1g", "--pids-limit=128",
             "docker.io/library/python:3.12-slim", "python3", "-"],
            input=source, capture_output=True, text=True, timeout=timeout)
        return p.returncode == 0
    except subprocess.TimeoutExpired:
        return False
    except Exception:
        return False


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, required=True)
    ap.add_argument("--tasks", required=True)
    ap.add_argument("--limit", type=int, default=0)
    ap.add_argument("--maxtok", type=int, default=640)
    ap.add_argument("--label", default="model")
    a = ap.parse_args()

    rows = [json.loads(l) for l in open(a.tasks) if l.strip()]
    if a.limit:
        rows = rows[:a.limit]

    passed = failed = 0
    for i, t in enumerate(rows, 1):
        try:
            code = extract(generate(a.port, t["prompt"], a.maxtok))
        except Exception as e:
            failed += 1
            continue
        # The task's own test plus the call that scores it.
        program = f"{code}\n\n{t['test']}\n\ncheck({t['entry_point']})\n"
        ok = run_sandboxed(program)
        passed += ok
        failed += (not ok)
        if i % 20 == 0:
            print(f"    {i}/{len(rows)}  pass {passed}", flush=True)

    total = passed + failed
    print(json.dumps({"label": a.label, "tasks": total, "passed": passed,
                      "pass_at_1": round(100.0 * passed / total, 1) if total else 0.0}))


if __name__ == "__main__":
    main()
