#!/usr/bin/env bash
# Is -c the TOTAL context across slots, or the context PER slot?
#
# This is load-bearing: if it is total, then raising -np trades context window
# for concurrency and opencode's limit.context has to move with it. If it is
# per-slot, that whole concern evaporates.
#
# Falsifiable: launch with -c 8192 -np 2 and ask the server. If a slot reports
# n_ctx 8192, -c is per-slot and I was wrong. If it reports 4096, it is total.
#
# Uses the 4B, not the 27B: these are llama.cpp semantics, not Kairic ones, and
# 4 GiB loads in seconds where 46 GiB does not.
set -uo pipefail
CTR=ctx-probe
PORT=8082
cleanup(){ podman rm -f "$CTR" >/dev/null 2>&1 || true; }
trap cleanup EXIT INT TERM
cleanup

podman run -d --rm --name "$CTR" \
  --device=/dev/kfd --device=/dev/dri --group-add keep-groups \
  --network=host -v "$HOME/models":/models:z \
  --entrypoint /engine/llama-server \
  -e HIP_VISIBLE_DEVICES=0 \
  localhost/kairic:v1.1 \
  -m /models/qwen3.8-4b/Qwen3.8-4B-Q8_0.gguf \
  --host 127.0.0.1 --port "$PORT" \
  -ngl 999 -c 8192 -np 2 -fa on --no-warmup >/dev/null || exit 1

for _ in $(seq 1 90); do
  curl -sf "http://127.0.0.1:$PORT/health" >/dev/null 2>&1 && break
  podman inspect "$CTR" >/dev/null 2>&1 || { echo "container died"; podman logs "$CTR" 2>&1 | tail -20; exit 1; }
  sleep 1
done

echo "=== what the server says about its slots ==="
curl -sf "http://127.0.0.1:$PORT/slots" 2>/dev/null \
  | python3 -c 'import json,sys; d=json.load(sys.stdin); print(f"  slots: {len(d)}"); [print(f"  slot {s.get(\"id\")}: n_ctx={s.get(\"n_ctx\")}") for s in d]' 2>/dev/null \
  || echo "  /slots unavailable"

echo "=== what the load log says ==="
podman logs "$CTR" 2>&1 | grep -iE 'n_ctx|n_ctx_per_seq|n_parallel|slots' | head -8 | sed 's/^/  /'

echo "=== VERDICT ==="
# The build logs this as "new slot, n_ctx = N" per slot; n_ctx_per_seq does
# not appear. Read the slot lines, which are unambiguous.
per_seq=$(podman logs "$CTR" 2>&1 | grep -oE 'new slot, n_ctx = [0-9]+' | head -1 | grep -oE '[0-9]+$')
if [ -n "$per_seq" ]; then
  [ "$per_seq" = "4096" ] && echo "  -c is TOTAL across slots (8192/2 = 4096 per seq)"
  [ "$per_seq" = "8192" ] && echo "  -c is PER SLOT (my claim to Nathan was wrong)"
else
  echo "  inconclusive from the log; see /slots above"
fi
