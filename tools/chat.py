#!/usr/bin/env python3
"""Stream a reply from the contract to the terminal, live, with a rate readout.

Prints tokens as they arrive rather than after the fact, because the point is
to feel the speed. Reports time-to-first-token separately from decode rate --
on this box those are very different numbers and the first one is what a long
prompt actually costs you.

These models think before answering. Reasoning tokens are dimmed rather than
hidden, so the wait is visible for what it is.
"""
import argparse, json, sys, time, urllib.request

DIM, RESET = "\033[2m", "\033[0m"

def stream(host, model, prompt, max_tokens, show_thinking):
    body = json.dumps({
        "model": model, "max_tokens": max_tokens, "stream": True,
        "messages": [{"role": "user", "content": prompt}],
    }).encode()
    req = urllib.request.Request(f"http://{host}/v1/chat/completions", data=body,
                                 headers={"Content-Type": "application/json"})
    t0 = time.time()
    first = None
    n_think = n_text = 0
    in_think = False
    with urllib.request.urlopen(req, timeout=1800) as r:
        for raw in r:
            line = raw.decode("utf-8", "replace").strip()
            if not line.startswith("data:"):
                continue
            payload = line[5:].strip()
            if payload == "[DONE]":
                break
            try:
                d = json.loads(payload)
            except json.JSONDecodeError:
                continue
            delta = (d.get("choices") or [{}])[0].get("delta", {})
            think = delta.get("reasoning_content") or delta.get("reasoning") or ""
            text = delta.get("content") or ""
            if think and show_thinking:
                if not in_think:
                    sys.stdout.write(DIM + "\n[thinking] "); in_think = True
                sys.stdout.write(think); sys.stdout.flush()
            if think:
                n_think += 1
                first = first if first is not None else time.time() - t0
            if text:
                if in_think:
                    sys.stdout.write(RESET + "\n\n"); in_think = False
                sys.stdout.write(text); sys.stdout.flush()
                n_text += 1
                first = first if first is not None else time.time() - t0
    if in_think:
        sys.stdout.write(RESET)
    dt = time.time() - t0
    total = n_think + n_text
    sys.stdout.write(
        f"\n\n{DIM}--- {model}: {total} chunks in {dt:.1f}s "
        f"({total/dt:.1f}/s) | first token {first:.1f}s | "
        f"{n_think} reasoning, {n_text} answer{RESET}\n")

if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("prompt", nargs="+")
    ap.add_argument("--model", default="fast")
    ap.add_argument("--host", default="127.0.0.1:8080")
    ap.add_argument("--max-tokens", type=int, default=1200)
    ap.add_argument("--hide-thinking", action="store_true")
    a = ap.parse_args()
    stream(a.host, a.model, " ".join(a.prompt), a.max_tokens, not a.hide_thinking)
