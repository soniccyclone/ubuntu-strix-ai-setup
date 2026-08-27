#!/usr/bin/env bash
# Two questions, answered on the 4B because they are llama.cpp questions and a
# 4 GiB model answers them in minutes where 46 GiB does not:
#
#  1. Does per-slot context SIZE affect decode rate at fixed concurrency? If it
#     does, a sweep that holds -c at 262144 and lets per-slot shrink confounds
#     concurrency with context and the design has to change.
#  2. What SHAPE does aggregate scaling have? This also proves the harness can
#     measure it at all before 46 GiB is committed to the real run.
#
# Falsifiable: (1) if c=8192 and c=262144 differ by more than a few percent at
# np=1, context size is a confound. (2) if aggregate does not rise with np, the
# harness is not actually running requests concurrently.
set -uo pipefail
CTR=shape4b
PORT=8082
HARNESS="$(dirname "$0")/conc-harness.py"
cleanup(){ podman rm -f "$CTR" >/dev/null 2>&1 || true; }
trap cleanup EXIT INT TERM
cleanup

launch(){ # ctx np
  podman run -d --rm --name "$CTR" \
    --device=/dev/kfd --device=/dev/dri --group-add keep-groups \
    --network=host -v "$HOME/models":/models:z \
    --entrypoint /engine/llama-server -e HIP_VISIBLE_DEVICES=0 \
    localhost/kairic:v1.1 \
    -m /models/qwen3.8-4b/Qwen3.8-4B-Q8_0.gguf \
    --host 127.0.0.1 --port "$PORT" -ngl 999 \
    -c "$1" -np "$2" -fa on -ctk f16 -ctv f16 --no-warmup >/dev/null || return 1
  for _ in $(seq 1 120); do
    curl -sf "http://127.0.0.1:$PORT/health" >/dev/null 2>&1 && return 0
    podman inspect "$CTR" >/dev/null 2>&1 || { echo "  died"; return 1; }
    sleep 1
  done; echo "  health timeout"; return 1
}

arm(){ # label ctx np streams
  printf '%-28s ' "$1"
  launch "$2" "$3" || { echo "LAUNCH FAILED"; return; }
  local slot_ctx
  slot_ctx=$(podman logs "$CTR" 2>&1 | grep -oE 'new slot, n_ctx = [0-9]+' | head -1 | grep -oE '[0-9]+$')
  local out; out=$(python3 "$HARNESS" "$PORT" "$4" 128 2>/dev/null)
  echo "slot_ctx=$slot_ctx  $out"
  cleanup
}

echo "== Q1: does per-slot context size change decode rate at np=1?"
arm "c=8192   np=1  1 stream"   8192   1 1
arm "c=262144 np=1  1 stream"   262144 1 1

echo
echo "== Q2: shape of aggregate scaling (c held at 262144, per-slot shrinks)"
arm "c=262144 np=2  2 streams"  262144 2 2
arm "c=262144 np=4  4 streams"  262144 4 4
arm "c=262144 np=8  8 streams"  262144 8 8
