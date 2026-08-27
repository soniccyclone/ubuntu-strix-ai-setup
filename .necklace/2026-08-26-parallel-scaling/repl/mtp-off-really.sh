#!/usr/bin/env bash
# --spec-type none zeroed draft_n in an earlier probe (prose, np=2, 64 tokens)
# and did NOT in the sweep (humaneval, np=1, 512 tokens): 7168 drafted tokens on
# an arm labelled "none". One of those two runs is lying about what it measured.
#
# One server, spec-type none, then a short prose request and a long humaneval
# one. If prose reports 0 and humaneval reports thousands, the flag is not the
# variable and --kairic-edge is bringing its own speculation.
#
# Falsifiable: if BOTH report 0, the sweep had some other defect. If both report
# non-zero, the earlier probe's zero was the anomaly.
set -uo pipefail
CTR=mtp-check
PORT=8086
K=/models/qwen3.8-kairic
RUNNER="$(cd "$(dirname "$0")" && pwd)/run-kairic-serve-spec.sh"
HE="$(dirname "$0")/../../2026-08-22-qwen38-27b/repl/humaneval.jsonl"
gtt(){ echo "$(( $(cat /sys/class/drm/card1/device/mem_info_gtt_used) / 1073741824 ))"; }
cleanup(){ podman rm -f "$CTR" >/dev/null 2>&1 || true; }
trap 'cleanup; echo "  [cleanup] GTT $(gtt) GiB"' EXIT INT TERM
cleanup

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
  -e KAIRIC_SLOTS=1 -e KAIRIC_SPEC_TYPE=none \
  -e KAIRIC_TEMP=0 -e KAIRIC_TOP_P=1.0 -e KAIRIC_TOP_K=0 \
  -e KAIRIC_REASONING=off -e KAIRIC_REASONING_FORMAT=none \
  -e HOST=127.0.0.1 -e PORT=$PORT \
  localhost/kairic:v1.1 /run.sh >/dev/null || exit 1

for _ in $(seq 1 200); do
  curl -sf "http://127.0.0.1:$PORT/health" >/dev/null 2>&1 && break
  podman inspect "$CTR" >/dev/null 2>&1 || { echo "died"; podman logs "$CTR" 2>&1|tail -15; exit 1; }
  sleep 2
done

echo "=== what the server says it launched with ==="
podman logs "$CTR" 2>&1 | grep -oE '\-\-spec-type [a-z-]+|\-\-kairic-edge' | sort -u | sed 's/^/  /'
echo "=== speculation init lines ==="
podman logs "$CTR" 2>&1 | grep -iE 'spec|draft|mtp' | grep -viE 'promptforge|record' | head -6 | sed 's/^/  /'

ask(){ # label maxtok prompt
  local r
  r=$(curl -sf -m 900 -H 'Content-Type: application/json' \
      -d "$(python3 -c 'import json,sys;print(json.dumps({"messages":[{"role":"user","content":sys.argv[1]}],"max_tokens":int(sys.argv[2]),"temperature":0,"top_p":1.0,"top_k":0,"stream":False}))' "$3" "$2")" \
      "http://127.0.0.1:$PORT/v1/chat/completions")
  echo "$r" | python3 -c "
import json,sys
t=json.load(sys.stdin).get('timings',{})
print(f\"  {sys.argv[1]:<26} predicted={t.get('predicted_n',0):<5} draft_n={t.get('draft_n',0):<6} accepted={t.get('draft_n_accepted',0)}\")" "$1"
}

echo "=== per-request draft counts with spec-type=none ==="
ask "prose, 64 tok"      64  "Explain how a page fault is serviced on x86-64."
ask "prose, 512 tok"     512 "Explain how a page fault is serviced on x86-64, in full detail."
HE1=$(head -1 "$HE" | python3 -c 'import json,sys;print("Complete the following Python function. Reply with the full function implementation in a single ```python code block.\n\n"+json.load(sys.stdin)["prompt"])')
ask "humaneval, 512 tok" 512 "$HE1"
