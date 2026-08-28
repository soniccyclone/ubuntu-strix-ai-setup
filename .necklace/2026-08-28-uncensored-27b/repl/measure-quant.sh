#!/usr/bin/env bash
# Serve each 4B quant directly (not through llama-swap), summarise every
# transcript at temp 0 (deterministic), score fact retention. Same flags as the
# compact role, minus the swap layer. Cleans up on every exit.
set -uo pipefail
REPO=/home/nathan/code-stuff/ubuntu-strix-ai-setup
SP="$(cd "$(dirname "$0")" && pwd)"
CTR=quantprobe
PORT=8094
gtt(){ awk '{printf "%.0f", $1/1073741824}' /sys/class/drm/card1/device/mem_info_gtt_used; }
cleanup(){ podman rm -f "$CTR" >/dev/null 2>&1 || true; echo "  [cleanup] GTT $(gtt) GiB"; }
trap cleanup EXIT INT TERM
cleanup

SYS='You are a summarisation worker performing conversation compaction. Summarise the conversation below into a concise handoff note that preserves every technical detail, identifier, number, file location, and decision, so another assistant can continue the work with nothing lost. Output only the summary.'

serve(){ # gguf-basename
  podman run -d --rm --name "$CTR" \
    --device=/dev/kfd --device=/dev/dri --group-add keep-groups \
    --network=host -v "$HOME/models":/models:z \
    -e HIP_VISIBLE_DEVICES=0 --entrypoint /engine/llama-server \
    localhost/kairic:v1.1 \
    -m "/models/qwen3.8-4b/$1" --alias q --host 127.0.0.1 --port "$PORT" \
    --jinja -dev ROCm0 -ngl 999 -c 16384 -fa on -ctk f16 -ctv f16 --no-warmup \
    --reasoning off --reasoning-format deepseek --temp 0 --top-k 1 >/dev/null || return 1
  for _ in $(seq 1 120); do curl -sf -m 2 "http://127.0.0.1:$PORT/health" >/dev/null 2>&1 && return 0
    podman inspect "$CTR" >/dev/null 2>&1 || return 1; sleep 1; done; return 1
}
summ(){ # which id convo
  python3 - "$SYS" "$3" > "$SP/body.json" <<'PY'
import json,sys
print(json.dumps({"model":"q","messages":[
 {"role":"system","content":sys.argv[1]},{"role":"user","content":sys.argv[2]}],
 "max_tokens":600,"temperature":0}))
PY
  curl -s -m 300 -X POST "http://127.0.0.1:$PORT/v1/chat/completions" \
    -H 'Content-Type: application/json' --data-binary @"$SP/body.json" > "$SP/sum-$1-$2.json"
}
run_all(){ # which gguf
  echo "== serving $2 as $1"; serve "$2" || { echo "  DID NOT START"; podman logs "$CTR" 2>&1|tail -5; return 1; }
  echo "  loaded, GTT $(gtt) GiB"
  python3 - "$SP" "$1" <<'PY'
import sys; sys.path.insert(0,sys.argv[1]); from corpus import CORPUS
open(sys.argv[1]+"/ids.txt","w").write("\n".join(c["id"] for c in CORPUS))
PY
  python3 - "$SP" <<'PY' | while IFS=$'\t' read -r id convo; do summ "$1" "$id" "$convo"; done
import sys,json; sys.path.insert(0,sys.argv[1]); from corpus import CORPUS
for c in CORPUS: print(c["id"]+"\t"+c["convo"].replace("\n"," "))
PY
  cleanup
}
# bash quirk: the while-read subshell above can't see $1. Redo explicitly:
run_all2(){ # which gguf
  echo "== serving $2 as $1"; serve "$2" || { echo "  DID NOT START"; podman logs "$CTR" 2>&1|tail -5; return 1; }
  echo "  loaded, GTT $(gtt) GiB"
  while IFS=$'\t' read -r id convo; do
    summ "$1" "$id" "$convo"
  done < <(python3 - "$SP" <<'PY'
import sys; sys.path.insert(0,sys.argv[1]); from corpus import CORPUS
for c in CORPUS: print(c["id"]+"\t"+c["convo"].replace("\n"," "))
PY
)
  echo "  summarised $(ls $SP/sum-$1-*.json 2>/dev/null | wc -l) transcripts"
  cleanup
}
run_all2 q8 Qwen3.8-4B-Q8_0.gguf
run_all2 q4 Qwen3.8-4B-Q4_K_M.gguf
echo "SUMMARIES_DONE"
