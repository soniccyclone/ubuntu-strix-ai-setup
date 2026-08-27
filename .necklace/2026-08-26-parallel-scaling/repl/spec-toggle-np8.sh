#!/usr/bin/env bash
# Two things the sweep's design depends on, neither of which is safe to assume.
#
# 1. Does --spec-type none actually disable MTP, and does llama-server tolerate
#    the --spec-draft-* flags still being on the command line beside it? If it
#    rejects them, the no-MTP arm needs a different runner, not a toggle.
#    Falsifiable: draft_n must be 0 with none and non-zero with draft-mtp.
#
# 2. Does resident memory grow with slot count? -c is total, so KV should be
#    flat, but the MTP draft path may allocate per slot. Eight arms of an hour
#    on a daily driver is the wrong place to discover otherwise.
#    Falsifiable: GTT at -np 8 should sit near the ~48 GiB measured at -np 1.
set -uo pipefail
CTR=spec-toggle
PORT=8084
K=/models/qwen3.8-kairic
HARNESS="$(dirname "$0")/conc-harness.py"
RUNNER="$(cd "$(dirname "$0")" && pwd)/run-kairic-serve-spec.sh"

gtt(){ echo "$(( $(cat /sys/class/drm/card1/device/mem_info_gtt_used) / 1073741824 ))"; }
cleanup(){ podman rm -f "$CTR" >/dev/null 2>&1 || true; }
trap 'cleanup; echo "  [cleanup] GTT $(gtt) GiB"' EXIT INT TERM
cleanup

arm(){ # spec_type slots
  local spec="$1" slots="$2"
  printf '  spec-type=%-10s np=%s  ' "$spec" "$slots"
  podman run -d --rm --name "$CTR" \
    --device=/dev/kfd --device=/dev/dri --group-add keep-groups \
    --network=host -v "$HOME/models":/models:z \
    -v "$RUNNER":/run.sh:ro,z --entrypoint /bin/bash \
    -e LLAMA_SERVER=/engine/llama-server \
    -e MODEL_PATH=$K/Qwen3.8-27B-IU4-Kairic-Edge.gguf \
    -e KAIRIC_FFN_SIDECAR=$K/Qwen3.8-27B-Kairic-IU4-FFN.pfs \
    -e KAIRIC_GDN_SIDECAR=$K/Qwen3.8-27B-Kairic-IU4-GDN.pfs \
    -e KAIRIC_GDN_OUTPUT_SIDECAR=$K/Qwen3.8-27B-Kairic-IU4-GDN-Output.pfs \
    -e KAIRIC_EDGE_COMPATIBILITY_MODE=1 \
    -e CONTEXT=262144 -e CACHE_RAM=16384 \
    -e KAIRIC_SLOTS="$slots" -e KAIRIC_SPEC_TYPE="$spec" \
    -e KAIRIC_TEMP=0 -e KAIRIC_TOP_P=1.0 -e KAIRIC_TOP_K=0 \
    -e KAIRIC_REASONING=off -e KAIRIC_REASONING_FORMAT=none \
    -e HOST=127.0.0.1 -e PORT=$PORT \
    localhost/kairic:v1.1 /run.sh >/dev/null || { echo "RUN FAILED"; return; }

  local up=0
  for _ in $(seq 1 200); do
    curl -sf "http://127.0.0.1:$PORT/health" >/dev/null 2>&1 && { up=1; break; }
    podman inspect "$CTR" >/dev/null 2>&1 || break
    sleep 2
  done
  if [ "$up" -ne 1 ]; then
    echo "DID NOT START"
    podman logs "$CTR" 2>&1 | grep -iE 'error|invalid|unrecognized|usage' | head -4 | sed 's/^/      /'
    cleanup; return
  fi

  local slot_ctx g out
  slot_ctx=$(podman logs "$CTR" 2>&1 | grep -oE 'new slot, n_ctx = [0-9]+' | head -1 | grep -oE '[0-9]+$')
  g=$(gtt)
  # jq, not a nested python f-string: the inner quoting broke once already.
  out=$(python3 "$HARNESS" "$PORT" "$slots" 64 2>/dev/null \
        | jq -r '"draft_n=\(.draft_n) accept=\(.draft_accept_pct) agg=\(.aggregate_tps)"')
  echo "GTT=${g}GiB slot_ctx=$slot_ctx $out"
  cleanup
}

echo "GTT before: $(gtt) GiB"
arm draft-mtp 2
arm none      2
