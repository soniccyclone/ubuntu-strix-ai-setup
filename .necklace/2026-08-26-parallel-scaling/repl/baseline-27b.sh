#!/usr/bin/env bash
# Does the published 41.89 reproduce, and do the MTP fields populate?
#
# Nathan posted that figure saying he had not hard-core vetted it. Before
# designing a sweep on top of it, check the foundation holds and that the
# instrumentation this cycle depends on (draft_n / draft_n_accepted) actually
# reports under the production runner.
#
# Conditions matched to how 41.89 was taken: HumanEval 0-9 chat-adapted, greedy,
# 512-token cap, reasoning off, hot cache (a full pass runs first and is
# discarded). Anything else is measuring a different thing.
#
# Falsifiable: if the hot single-stream figure lands far from 41.89, or draft_n
# comes back 0, the premise of this cycle needs revisiting before any sweep.
set -uo pipefail
CTR=kairic-baseline
PORT=8083
HE="$(dirname "$0")/../../2026-08-22-qwen38-27b/repl/humaneval.jsonl"
K=/models/qwen3.8-kairic
NTASK="${NTASK:-10}"
MAXTOK=512

gtt(){ echo "$(( $(cat /sys/class/drm/card1/device/mem_info_gtt_used) / 1073741824 )) GiB"; }
cleanup(){ podman rm -f "$CTR" >/dev/null 2>&1 || true; }
trap 'cleanup; echo "  [cleanup] GTT now $(gtt)"' EXIT INT TERM
cleanup

[ -r "$HE" ] || { echo "no humaneval.jsonl at $HE" >&2; exit 1; }
echo "GTT before: $(gtt)"

podman run -d --rm --name "$CTR" \
  --device=/dev/kfd --device=/dev/dri --group-add keep-groups \
  --network=host -v "$HOME/models":/models:z \
  -v "$PWD/../../../config/run-kairic-serve.sh":/run-kairic-serve.sh:ro,z \
  --entrypoint /bin/bash \
  -e LLAMA_SERVER=/engine/llama-server \
  -e MODEL_PATH=$K/Qwen3.8-27B-IU4-Kairic-Edge.gguf \
  -e KAIRIC_FFN_SIDECAR=$K/Qwen3.8-27B-Kairic-IU4-FFN.pfs \
  -e KAIRIC_GDN_SIDECAR=$K/Qwen3.8-27B-Kairic-IU4-GDN.pfs \
  -e KAIRIC_GDN_OUTPUT_SIDECAR=$K/Qwen3.8-27B-Kairic-IU4-GDN-Output.pfs \
  -e KAIRIC_EDGE_COMPATIBILITY_MODE=1 \
  -e CONTEXT=262144 -e CACHE_RAM=16384 \
  -e KAIRIC_SLOTS=1 \
  -e KAIRIC_TEMP=0 -e KAIRIC_TOP_P=1.0 -e KAIRIC_TOP_K=0 \
  -e KAIRIC_REASONING=off -e KAIRIC_REASONING_FORMAT=none \
  -e HOST=127.0.0.1 -e PORT=$PORT \
  localhost/kairic:v1.1 /run-kairic-serve.sh >/dev/null || exit 1

echo -n "loading"
for _ in $(seq 1 300); do
  curl -sf "http://127.0.0.1:$PORT/health" >/dev/null 2>&1 && { echo " up"; break; }
  podman inspect "$CTR" >/dev/null 2>&1 || { echo " DIED"; podman logs "$CTR" 2>&1|tail -25; exit 1; }
  printf '.'; sleep 2
done
echo "GTT loaded: $(gtt)"

pass(){ # label
  local label="$1" i=0 tok=0 ms=0 dn=0 da=0
  while IFS= read -r line && [ "$i" -lt "$NTASK" ]; do
    body=$(python3 -c '
import json,sys
t=json.loads(sys.argv[1])
m=("Complete the following Python function. Reply with the full function "
   "implementation in a single ```python code block.\n\n"+t["prompt"])
print(json.dumps({"messages":[{"role":"user","content":m}],"max_tokens":int(sys.argv[2]),
 "temperature":0,"top_p":1.0,"top_k":0,"stream":False}))' "$line" "$MAXTOK")
    resp=$(curl -sf -m 900 -H 'Content-Type: application/json' -d "$body" \
            "http://127.0.0.1:$PORT/v1/chat/completions") || { echo "  request failed"; return 1; }
    read -r a b c d < <(python3 -c '
import json,sys
t=json.loads(sys.argv[1]).get("timings",{})
print(t.get("predicted_n",0), t.get("predicted_ms",0.0), t.get("draft_n",0), t.get("draft_n_accepted",0))' "$resp")
    tok=$((tok+a)); ms=$(python3 -c "print($ms+$b)"); dn=$((dn+c)); da=$((da+d)); i=$((i+1))
  done < "$HE"
  python3 -c "
import sys
lbl=sys.argv[1]
tok,ms,dn,da=$tok,$ms,$dn,$da
rate=tok/(ms/1000) if ms else 0
acc=f'{100*da/dn:.1f}%' if dn else 'n/a (NO SPECULATION)'
print(f'  {lbl}: {rate:.2f} tok/s over {tok} tok; draft_n={dn} accept={acc}')" "$label"
}

pass "cold"
pass "hot "
pass "hot "
echo "GTT peak: $(gtt)"
