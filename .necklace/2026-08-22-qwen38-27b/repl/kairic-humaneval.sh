#!/usr/bin/env bash
# HumanEval 0-9 against Kairic's own published "hot slice" of 48.78 tok/s.
#
# Supersedes kairic-bench.sh, which had two defects: it never ran Kairic's
# release configuration (262144 context, 8 GiB prompt cache, -ctxcp 32), and it
# gave the Kairic arm --spec-draft-backend-sampling and --spec-draft-p-min 0
# while giving the ROCmFP4 arm neither, so the MTP arms were not matched.
#
# Kairic is launched through the vendor's own scripts/run-kairic-edge-gfx1151.sh
# rather than hand-copied flags, so a transcription slip cannot be the answer.
# Draft acceptance is recorded, because a speculation number without an
# acceptance rate does not say whether speculation happened.
set -uo pipefail

CTR=kairic-he
PORT=8081
HE="$(dirname "$0")/humaneval.jsonl"
NTASK="${NTASK:-10}"
MAXTOK="${MAXTOK:-512}"
OUT="${1:-/tmp/kairic-he.tsv}"

cleanup(){ podman rm -f "$CTR" >/dev/null 2>&1 || true; }
trap cleanup EXIT INT TERM
cleanup

wait_up(){ for _ in $(seq 1 300); do
    curl -sf "http://127.0.0.1:$PORT/health" >/dev/null 2>&1 && return 0
    podman inspect "$CTR" >/dev/null 2>&1 || { echo "  container died:"; podman logs "$CTR" 2>&1|tail -12; return 1; }
    sleep 2; done; echo "  health timeout"; return 1; }

# One pass over tasks 0..N-1. Emits: sum_tokens sum_predicted_ms draft_n draft_acc
run_pass(){
  local label="$1" i=0 tok=0 ms=0 dn=0 da=0
  while IFS= read -r line && [ "$i" -lt "$NTASK" ]; do
    local body resp
    body=$(python3 -c '
import json,sys
t=json.loads(sys.argv[1])
msg=("Complete the following Python function. Reply with the full function "
     "implementation in a single ```python code block.\n\n"+t["prompt"])
print(json.dumps({"messages":[{"role":"user","content":msg}],
  "max_tokens":int(sys.argv[2]),"temperature":0,"top_p":1.0,"top_k":0,"stream":False}))' "$line" "$MAXTOK")
    resp=$(curl -sf -m 900 -H 'Content-Type: application/json' -d "$body" \
            "http://127.0.0.1:$PORT/v1/chat/completions") || { echo "    task $i ERR" >&2; i=$((i+1)); continue; }
    read -r a b c d < <(python3 -c '
import json,sys
r=json.loads(sys.argv[1]); t=r.get("timings",{})
print(t.get("predicted_n",0), t.get("predicted_ms",0.0),
      t.get("draft_n",0), t.get("draft_n_accepted",0))' "$resp")
    tok=$((tok+a)); ms=$(python3 -c "print($ms+$b)"); dn=$((dn+c)); da=$((da+d))
    i=$((i+1))
  done < "$HE"
  python3 -c "
tok,ms,dn,da=$tok,$ms,$dn,$da
tps=tok/(ms/1000) if ms>0 else 0
acc=(100.0*da/dn) if dn else 0.0
print(f'   $label: {tps:.2f} tok/s aggregate  ({tok} tok / {ms/1000:.1f} s)  draft accept {acc:.1f}% ({da}/{dn})')
print(f'$label\t{tps:.2f}\t{tok}\t{ms/1000:.1f}\t{acc:.1f}', file=open('$OUT','a'))"
}

arm(){
  local name="$1"; shift
  echo "== $name"
  podman run -d --rm --name "$CTR" --device=/dev/kfd --device=/dev/dri \
    --group-add keep-groups --network=host -v "$HOME/models":/models:z "$@" >/dev/null || {
      echo "  launch failed"; return; }
  wait_up || { cleanup; return; }
  run_pass "$name cold"
  run_pass "$name hot"     # their 48.78 is a HOT slice; the cache must be warm
  echo "   peak-check: single longest task repeated"
  cleanup
}

: > "$OUT"
K=/models/qwen3.8-kairic

# --- Kairic, vendor runner, vendor defaults (262144 ctx, 8 GiB cache, ctxcp 32)
[[ "${ARMS:-all}" == *kairic* || "${ARMS:-all}" == all ]] && \
arm "kairic" --entrypoint /bin/bash \
  -e LLAMA_SERVER=/engine/llama-server \
  -e MODEL_PATH=$K/Qwen3.8-27B-IU4-Kairic-Edge.gguf \
  -e KAIRIC_FFN_SIDECAR=$K/Qwen3.8-27B-Kairic-IU4-FFN.pfs \
  -e KAIRIC_GDN_SIDECAR=$K/Qwen3.8-27B-Kairic-IU4-GDN.pfs \
  -e KAIRIC_GDN_OUTPUT_SIDECAR=$K/Qwen3.8-27B-Kairic-IU4-GDN-Output.pfs \
  -e PORT=$PORT -e HOST=127.0.0.1 -e KAIRIC_EDGE_COMPATIBILITY_MODE=${COMPAT:-0} \
  localhost/kairic:v1.1 /src/scripts/run-kairic-edge-gfx1151.sh

# --- ROCmFP4 with the SAME speculation settings the Kairic runner uses
[[ "${ARMS:-all}" == *rocm* || "${ARMS:-all}" == all ]] && \
arm "rocmfp4" --entrypoint /engine/llama-server -e HIP_VISIBLE_DEVICES=0 \
  localhost/rocmfpx-hip:0fc9568 \
  -m /models/qwen3.8-27b/ROCmFP4-FAST.gguf --alias main --host 127.0.0.1 --port $PORT \
  --jinja -dev ROCm0 -ngl 999 -c 262144 -b 2048 -ub 512 -fa on -ctk f16 -ctv f16 \
  -t 16 -tb 32 -np 1 -ctxcp 32 --cache-ram 8192 --cache-prompt --cache-idle-slots --metrics \
  --spec-type draft-mtp --spec-draft-device ROCm0 --spec-draft-ngl 999 \
  --spec-draft-type-k f16 --spec-draft-type-v f16 \
  --spec-draft-n-max 4 --spec-draft-n-min 0 --spec-draft-p-min 0.0 \
  --spec-draft-p-split 0.10 --spec-draft-backend-sampling \
  --temp 0 --top-p 1.0 --top-k 0 --min-p 0.0 \
  --reasoning off --reasoning-format none --reasoning-budget -1

echo; echo "=== $OUT ==="; column -t "$OUT" 2>/dev/null || cat "$OUT"
