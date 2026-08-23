#!/usr/bin/env bash
# Kairic Edge vs ROCmFP4, one driver, same prompts, same token budget.
#
# The earlier ROCmFP4 MTP figure (22.7 tok/s) was taken by hand. Re-measuring it
# here under the identical driver rather than quoting it, so the comparison is
# a comparison and not a recollection.
#
# Every arm starts one container and stops it in a trap, so an abort or a failed
# curl still leaves the machine clean. Never leave a 26 GiB model resident.
set -uo pipefail

CTR=kairic-bench
PORT=8081
MDIR="$HOME/models"
OUT="${1:-/tmp/kairic-bench.tsv}"

cleanup() { podman rm -f "$CTR" >/dev/null 2>&1 || true; }
trap cleanup EXIT INT TERM
cleanup

# Deliberately mixed: a short factual answer, a reasoning task, and a code task.
# Decode rate on a hybrid-attention model varies with what it is producing.
declare -a PROMPTS=(
  "Explain in detail how a page fault is serviced on x86-64, from the CPU fault through to the process resuming."
  "Write a complete C function that inserts a node into a red-black tree, including the rebalancing cases, with comments."
  "Compare magnetic drum memory with modern DRAM: access model, latency, cost per bit, and why the industry moved."
)
MAXTOK=384

start_server() {
  local name="$1"; shift
  podman run -d --rm --name "$CTR" \
    --device=/dev/kfd --device=/dev/dri --group-add keep-groups \
    --network=host -v "$MDIR":/models:z \
    "$@" >/dev/null || return 1
  for _ in $(seq 1 180); do
    curl -sf "http://127.0.0.1:$PORT/health" >/dev/null 2>&1 && return 0
    podman inspect "$CTR" >/dev/null 2>&1 || { echo "  $name: container died" >&2; return 1; }
    sleep 2
  done
  echo "  $name: health timeout" >&2; return 1
}

# Returns "tok/s tokens" using the server's own timings when it reports them,
# else end-to-end wall clock, which is what the operator actually feels.
run_prompt() {
  local p="$1" t0 t1 body toks tps
  body=$(python3 -c '
import json,sys
print(json.dumps({"messages":[{"role":"user","content":sys.argv[1]}],
 "max_tokens":int(sys.argv[2]),"temperature":0,"top_p":1.0,"top_k":0,"stream":False}))' "$p" "$MAXTOK")
  t0=$(date +%s.%N)
  resp=$(curl -sf -m 900 -H 'Content-Type: application/json' -d "$body" \
          "http://127.0.0.1:$PORT/v1/chat/completions") || { echo "ERR 0"; return; }
  t1=$(date +%s.%N)
  python3 -c '
import json,sys
r=json.loads(sys.argv[1]); wall=float(sys.argv[2])
tk=r.get("usage",{}).get("completion_tokens",0)
tm=r.get("timings",{})
tps=tm.get("predicted_per_second") or (tk/wall if wall>0 else 0)
print(f"{tps:.2f} {tk}")' "$resp" "$(echo "$t1 - $t0" | bc)"
}

bench_arm() {
  local name="$1"; shift
  echo "== $name"
  start_server "$name" "$@" || { echo -e "$name\tFAILED\t0" >> "$OUT"; cleanup; return; }
  run_prompt "warmup: say ok" >/dev/null            # exclude first-call graph build
  local sum=0 n=0
  for p in "${PROMPTS[@]}"; do
    read -r tps toks < <(run_prompt "$p")
    echo "   $tps tok/s  ($toks tok)"
    echo -e "$name\t$tps\t$toks" >> "$OUT"
    sum=$(echo "$sum + $tps" | bc); n=$((n+1))
  done
  echo "   mean $(echo "scale=2; $sum / $n" | bc) tok/s"
  # Does this arm serve a grammar-constrained request? That is what the agent
  # suite needs and what the argmax fast path refuses.
  g=$(curl -sf -m 120 -H 'Content-Type: application/json' -d '{"messages":[{"role":"user","content":"Name one color."}],"max_tokens":24,"temperature":0,"top_p":1.0,"top_k":0,"response_format":{"type":"json_schema","json_schema":{"name":"c","schema":{"type":"object","properties":{"color":{"type":"string"}},"required":["color"]}}}}' \
        "http://127.0.0.1:$PORT/v1/chat/completions" 2>&1)
  if echo "$g" | grep -q '"content"'; then echo "   grammar: SERVED"; echo -e "$name\tgrammar\tSERVED" >> "$OUT"
  else echo "   grammar: REFUSED"; echo -e "$name\tgrammar\tREFUSED" >> "$OUT"; fi
  cleanup
}

: > "$OUT"

K=/models/qwen3.8-kairic
KARGS=(-m $K/Qwen3.8-27B-IU4-Kairic-Edge.gguf --alias main --host 127.0.0.1 --port $PORT
  --jinja -dev ROCm0 -ngl 999 -c 32768 -b 2048 -ub 512 -fa on -ctk f16 -ctv f16
  -t 16 -tb 32 -np 1 --cache-prompt --metrics --kairic-edge
  --spec-type draft-mtp --spec-draft-device ROCm0 --spec-draft-ngl 999
  --spec-draft-type-k f16 --spec-draft-type-v f16
  --spec-draft-n-max 4 --spec-draft-n-min 0 --spec-draft-p-min 0.0
  --spec-draft-p-split 0.10 --spec-draft-backend-sampling
  --temp 0 --top-p 1.0 --top-k 0 --min-p 0.0
  --reasoning off --reasoning-format none --reasoning-budget -1)

# Sidecar wiring copied verbatim from scripts/run-kairic-edge-gfx1151.sh.
kenv() {
  echo "-e ROCM_PATH=/opt/rocm -e HIP_VISIBLE_DEVICES=0 -e HSA_OVERRIDE_GFX_VERSION=11.5.1
 -e GGML_CUDA_GRAPH_OPT=0 -e LLAMA_MTP_CPU_ARGMAX_FASTPATH=1
 -e LLAMA_TARGET_GREEDY_ARGMAX_FASTPATH=$1
 -e PROMPTFORGE_TARGET_ONLY=0 -e PROMPTFORGE_MODE=iu4_ffn
 -e PROMPTFORGE_IU4_SIDECAR=$K/Qwen3.8-27B-Kairic-IU4-FFN.pfs
 -e PROMPTFORGE_SIDECAR=$K/Qwen3.8-27B-Kairic-IU4-FFN.pfs
 -e PROMPTFORGE_IU4_HADAMARD=1 -e PROMPTFORGE_IU4_SEGMENTED=0
 -e PROMPTFORGE_ENABLE_FFN_KEEPERS=0 -e PROMPTFORGE_FFN_KEEPERS=late6
 -e PROMPTFORGE_ENABLE_GDN=1 -e PROMPTFORGE_ENABLE_GDN_W8=0
 -e PROMPTFORGE_GDN_SIDECAR_OVERRIDE=$K/Qwen3.8-27B-Kairic-IU4-GDN.pfs
 -e PROMPTFORGE_GDN_SIDECAR=$K/Qwen3.8-27B-Kairic-IU4-GDN.pfs
 -e PROMPTFORGE_GDN_IU4_HADAMARD=1 -e PROMPTFORGE_ENABLE_GDN_KEEPERS=0
 -e PROMPTFORGE_ENABLE_GDN_OUTPUT=1
 -e PROMPTFORGE_GDN_OUTPUT_SIDECAR=$K/Qwen3.8-27B-Kairic-IU4-GDN-Output.pfs
 -e PROMPTFORGE_GDN_OUTPUT_KEEPERS=v3_lateq6
 -e PROMPTFORGE_ENABLE_SMALLM_IU4=1 -e PROMPTFORGE_ENABLE_SMALLM_GDN_IU4=1
 -e PROMPTFORGE_ENABLE_SMALLM_GDN_OUTPUT_IU4=0
 -e PROMPTFORGE_ENABLE_IU4_DECODE_M2_M5=0
 -e PROMPTFORGE_OUTPUT_K8_STRICT_GREEDY=0"
}

[[ "${ARMS:-all}" == *fast* || "${ARMS:-all}" == all ]] && bench_arm "kairic-fastpath"  $(kenv 1) localhost/kairic:v1.1 "${KARGS[@]}"
[[ "${ARMS:-all}" == *compat* || "${ARMS:-all}" == all ]] && bench_arm "kairic-compat"    $(kenv 0) localhost/kairic:v1.1 "${KARGS[@]}"

[[ "${ARMS:-all}" == *rocm* || "${ARMS:-all}" == all ]] && bench_arm "rocmfp4-mtp" -e HIP_VISIBLE_DEVICES=0 --entrypoint /engine/llama-server localhost/rocmfpx-hip:0fc9568 \
  -m /models/qwen3.8-27b/ROCmFP4-FAST.gguf --alias main --host 127.0.0.1 --port $PORT \
  --jinja -dev ROCm0 -ngl 999 -c 32768 -b 2048 -ub 512 -fa on -ctk f16 -ctv f16 \
  -t 16 -tb 32 -np 1 --cache-prompt --metrics --spec-type draft-mtp \
  --spec-draft-device ROCm0 --spec-draft-ngl 999 --spec-draft-n-max 4

echo; echo "=== $OUT ==="; cat "$OUT"
