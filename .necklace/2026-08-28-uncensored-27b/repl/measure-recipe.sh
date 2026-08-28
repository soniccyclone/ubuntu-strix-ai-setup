#!/usr/bin/env bash
# Step 3: the number that fills the bracket.
#
#   ROCmFP4 base alone          ~22   measured, previous cycle
#   uniform ROCmI4              ~35   measured, this cycle
#   mixed-precision base         ???  <- here, no sidecars
#   ROCmFP4/Q6 base + sidecars   ~48   Kairic as shipped
#
# Near 45 and the unpublished sidecar packer barely matters. Near 25 and it is
# the only route to Kairic-class speed on uncensored weights.
#
# Served on the same engine as the ROCmI4 arm, at Kairic's own serving flags
# rather than cafonez's, because this is Kairic's recipe -- a 4-token draft
# window and p-min 0, not 16 and 0.60. Same harness, same pool, five repeats.
set -uo pipefail
REPO="$(cd "$(dirname "$0")/../../.." && pwd)"
HERE="$(cd "$(dirname "$0")" && pwd)"
CTR=recipeprobe
PORT=8091
OUT="${OUT:-$HERE/recipe-result.tsv}"
MODEL=/models/qwen3.8-ablit-work/Qwen3.8-27B-ablit-KairicRecipe.gguf
TASKS="$REPO/.necklace/2026-08-22-qwen38-27b/repl/humaneval.jsonl"
HARNESS="$REPO/tools/concbench.py"

gtt(){ echo $(( $(cat /sys/class/drm/card1/device/mem_info_gtt_used) / 1073741824 )); }
cleanup(){ podman rm -f "$CTR" >/dev/null 2>&1 || true; }
trap 'cleanup; echo "  [cleanup] GTT $(gtt) GiB"' EXIT INT TERM
cleanup

echo "GTT before: $(gtt) GiB"
podman run -d --rm --name "$CTR" \
  --device=/dev/kfd --device=/dev/dri --group-add keep-groups \
  --network=host -v "$HOME/models":/models:z \
  -e HIP_VISIBLE_DEVICES=0 -e HSA_OVERRIDE_GFX_VERSION=11.5.1 \
  localhost/rocmi4:c49ebdbd \
  -m "$MODEL" --host 127.0.0.1 --port "$PORT" --alias ablit-kairic-recipe \
  -dev ROCm0 -ngl 999 -np 1 -c 262144 \
  -b 2048 -ub 512 -t 16 -tb 32 -fa on -ctk f16 -ctv f16 --jinja \
  --cache-prompt --cache-ram 16384 \
  --spec-type draft-mtp --spec-draft-device ROCm0 --spec-draft-ngl 999 \
  --spec-draft-type-k f16 --spec-draft-type-v f16 \
  --spec-draft-n-max 4 --spec-draft-n-min 0 --spec-draft-p-min 0.0 \
  --spec-draft-backend-sampling \
  --reasoning off --reasoning-format deepseek >/dev/null || { echo "LAUNCH FAILED"; exit 1; }

for _ in $(seq 1 240); do
  curl -sf "http://127.0.0.1:$PORT/health" >/dev/null 2>&1 && break
  podman inspect "$CTR" >/dev/null 2>&1 || { echo "DIED"; podman logs "$CTR" 2>&1 | tail -15; exit 1; }
  sleep 2
done

# Whether speculation is live at all, and whether the mixed types loaded.
podman logs "$CTR" 2>&1 | grep -iE 'ROCMI4|ROCMFP4|Q6_0|speculative implementation|W4A4' | head -6 | sed 's/^/  /'
used=$(gtt)
out=$(python3 "$HARNESS" --port "$PORT" --streams 1 --reps 5 --maxtok 512 \
        --workload humaneval --tasks "$TASKS" 2>/dev/null)
[ -z "$out" ] && { echo "MEASUREMENT FAILED"; exit 1; }
[ -s "$OUT" ] || printf 'arm\tper_stream_tps\tspread_pct\taggregate_tps\tdraft_n\taccept_pct\tgtt_gib\n' > "$OUT"
echo "$out" | python3 -c "
import json,sys
d=json.load(sys.stdin)
row=['ablit-kairic-recipe',str(d['per_stream_tps']),str(d['per_stream_spread_pct']),
     str(d['aggregate_tps']),str(d['draft_n']),str(d['draft_accept_pct']),'$used']
open('$OUT','a').write('\t'.join(row)+'\n')
print(f\"\n  RESULT  per-stream {d['per_stream_tps']} (+/-{d['per_stream_spread_pct']}%)  \"
      f\"accept {d['draft_accept_pct']}  GTT ${used}GiB\")
print('  bracket: rocmfp4 ~22 | rocmi4 ~35 | THIS | kairic ~48')"
echo "MEASURE_DONE"
