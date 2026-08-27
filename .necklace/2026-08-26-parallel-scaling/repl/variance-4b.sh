#!/usr/bin/env bash
# How noisy is a single measurement on this box?
#
# Q1 of shape-4b.sh showed 26.23 vs 28.87 tok/s for a config change that cannot
# affect decode rate. Either that is run-to-run noise, or something real is
# going on. It matters: MTP's effect at higher concurrency may be a handful of
# percent, and a claim smaller than the noise floor is not a claim.
#
# Two kinds of spread, and they are not the same:
#   WITHIN  repeated measurements against one running server
#   ACROSS  one measurement each against separately launched servers
#
# Falsifiable: if within-server spread is under ~2% and across-server spread is
# ~10%, the noise is in model load / memory placement, and the real benchmark
# must relaunch per arm and repeat. If both are ~10%, repeats alone fix it.
set -uo pipefail
CTR=var4b
PORT=8082
HARNESS="$(dirname "$0")/conc-harness.py"
REPS="${REPS:-5}"
cleanup(){ podman rm -f "$CTR" >/dev/null 2>&1 || true; }
trap cleanup EXIT INT TERM
cleanup

launch(){
  podman run -d --rm --name "$CTR" \
    --device=/dev/kfd --device=/dev/dri --group-add keep-groups \
    --network=host -v "$HOME/models":/models:z \
    --entrypoint /engine/llama-server -e HIP_VISIBLE_DEVICES=0 \
    localhost/kairic:v1.1 \
    -m /models/qwen3.8-4b/Qwen3.8-4B-Q8_0.gguf \
    --host 127.0.0.1 --port "$PORT" -ngl 999 \
    -c 262144 -np 1 -fa on -ctk f16 -ctv f16 --no-warmup >/dev/null || return 1
  for _ in $(seq 1 120); do
    curl -sf "http://127.0.0.1:$PORT/health" >/dev/null 2>&1 && return 0
    sleep 1
  done; return 1
}

stats(){ python3 -c '
import sys,statistics as s
v=[float(x) for x in sys.argv[1:]]
m=s.mean(v); sd=s.stdev(v) if len(v)>1 else 0.0
print(f"  n={len(v)} mean={m:.2f} sd={sd:.2f} spread={100*(max(v)-min(v))/m:.1f}%  values={[round(x,2) for x in v]}")' "$@"; }

echo "== WITHIN one server ($REPS measurements, no relaunch)"
launch || { echo "launch failed"; exit 1; }
w=()
for _ in $(seq "$REPS"); do
  w+=( "$(python3 "$HARNESS" "$PORT" 1 128 | python3 -c 'import json,sys; print(json.load(sys.stdin)["per_stream_tps_mean"])')" )
done
stats "${w[@]}"
cleanup

echo
echo "== ACROSS servers ($REPS launches, one measurement each)"
a=()
for _ in $(seq "$REPS"); do
  launch || { echo "  launch failed"; continue; }
  a+=( "$(python3 "$HARNESS" "$PORT" 1 128 | python3 -c 'import json,sys; print(json.load(sys.stdin)["per_stream_tps_mean"])')" )
  cleanup
done
stats "${a[@]}"
