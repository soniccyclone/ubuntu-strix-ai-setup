#!/usr/bin/env bash
# HumanEval pass@1 across the variants, plus throughput on the same server.
#
# Throughput has been measured to death; nothing has measured whether any of
# these quantisations broke the model. W4A4 announces itself as a lossy
# prompt-processing path and Kairic spends bits promoting fifty tensors, but
# neither fact is a measurement.
#
# The bf16 arm is the control that makes the others readable: it separates what
# abliteration cost from what quantisation cost. Without it a low score cannot
# be attributed to either. It is slow -- unquantised 27B is bandwidth-bound at
# roughly 5 tok/s -- so it runs last and can be skipped.
set -uo pipefail
REPO="$(cd "$(dirname "$0")/../../.." && pwd)"
HERE="$(cd "$(dirname "$0")" && pwd)"
CTR=qualprobe
PORT=8092
OUT="$HERE/quality.tsv"
TASKS="$REPO/.necklace/2026-08-22-qwen38-27b/repl/humaneval.jsonl"
LIMIT="${LIMIT:-164}"
W=/models/qwen3.8-ablit-work

gtt(){ echo $(( $(cat /sys/class/drm/card1/device/mem_info_gtt_used) / 1073741824 )); }
cleanup(){ podman rm -f "$CTR" >/dev/null 2>&1 || true; }
trap 'cleanup; echo "  [cleanup] GTT $(gtt) GiB"' EXIT INT TERM
cleanup
[ -s "$OUT" ] || printf 'arm\tmodel\ttasks\tpassed\tpass_at_1\ttok_s\n' > "$OUT"

serve(){ # model-path extra-args...
  local m="$1"; shift
  podman run -d --rm --name "$CTR" \
    --device=/dev/kfd --device=/dev/dri --group-add keep-groups \
    --network=host -v "$HOME/models":/models:z \
    -e HIP_VISIBLE_DEVICES=0 -e HSA_OVERRIDE_GFX_VERSION=11.5.1 \
    localhost/rocmi4:c49ebdbd \
    -m "$m" --host 127.0.0.1 --port "$PORT" \
    -dev ROCm0 -ngl 999 -np 1 -c 32768 \
    -b 2048 -ub 512 -t 16 -tb 32 -fa on -ctk f16 -ctv f16 --jinja \
    --cache-prompt --cache-ram 8192 \
    --reasoning off --reasoning-format deepseek "$@" >/dev/null || return 1
  for _ in $(seq 1 300); do
    curl -sf "http://127.0.0.1:$PORT/health" >/dev/null 2>&1 && return 0
    podman inspect "$CTR" >/dev/null 2>&1 || return 1
    sleep 2
  done; return 1
}

arm(){ # label model extra...
  local label="$1" model="$2"; shift 2
  echo "== $label"
  cleanup
  serve "$model" "$@" || { echo "  LAUNCH FAILED"; return; }
  local r; r=$(python3 "$REPO/tools/humaneval_score.py" --port "$PORT" \
        --tasks "$TASKS" --limit "$LIMIT" --label "$label" 2>/dev/null | tail -1)
  [ -z "$r" ] && { echo "  SCORING FAILED"; cleanup; return; }
  local t; t=$(python3 "$REPO/tools/concbench.py" --port "$PORT" --streams 1 \
        --reps 5 --maxtok 512 --workload humaneval --tasks "$TASKS" 2>/dev/null \
        | python3 -c 'import json,sys;print(json.load(sys.stdin)["per_stream_tps"])' 2>/dev/null)
  echo "$r" | python3 -c "
import json,sys
d=json.load(sys.stdin)
open('$OUT','a').write('\t'.join(['$label','$(basename "$model")',str(d['tasks']),
  str(d['passed']),str(d['pass_at_1']),'${t:-}'])+'\n')
print(f\"  pass@1 {d['pass_at_1']}%  ({d['passed']}/{d['tasks']})   {'${t:-?}'} tok/s\")"
  cleanup
}

MTP=(--spec-type draft-mtp --spec-draft-device ROCm0 --spec-draft-ngl 999
     --spec-draft-type-k f16 --spec-draft-type-v f16
     --spec-draft-n-max 16 --spec-draft-n-min 0 --spec-draft-p-min 0.60
     --spec-draft-backend-sampling)

arm "ablit-rocmi4"  "$W/Qwen3.8-27B-ablit-ROCMI4.gguf"        "${MTP[@]}"
arm "ablit-recipe"  "$W/Qwen3.8-27B-ablit-KairicRecipe.gguf"  "${MTP[@]}"
echo; echo "wrote $OUT"
