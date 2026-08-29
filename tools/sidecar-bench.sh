#!/usr/bin/env bash
# Serve a GGUF with packed IU4 sidecars on Kairic's own engine and runner, then
# measure it. Two arms:
#   stock  Kairic's GGUF + sidecars packed by repl/pack_pfs.py from stock bf16.
#          Must land at the kairic-ref number (48.75 +/-6.5%) or the packer is
#          wrong in a way the byte-diff did not see.
#   ablit  abliterated KairicRecipe GGUF + sidecars packed from ablit-bf16.
# Same flags as rocmi4-vs-kairic.sh's kairic-ref arm: compatibility mode,
# greedy, reasoning off, one slot, five repeats on the HumanEval pool.
# QUALITY=1 also scores HumanEval pass@1 (LIMIT tasks, default 164).
# The Kairic install is untouched: run-kairic-serve.sh is mounted read-only.
set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HERE="$(cd "$(dirname "$0")" && pwd)"
CTR=pfsprobe
PORT=8093
OUT="${OUT:-$REPO/bench/sidecar-bench.tsv}"
QOUT="${QOUT:-$REPO/bench/sidecar-quality.tsv}"
TASKS="$REPO/.necklace/2026-08-22-qwen38-27b/repl/humaneval.jsonl"
MODELS="${MODELS:-$HOME/models}"
ARMS="${ARMS:-stock ablit}"
STOCK_PFS="${STOCK_PFS:-/models/qwen3.8-stock-work/pfs}"
ABLIT_PFS="${ABLIT_PFS:-/models/qwen3.8-ablit-work/pfs}"

gtt(){ echo $(( $(cat /sys/class/drm/card1/device/mem_info_gtt_used) / 1073741824 )); }
cleanup(){ podman rm -f "$CTR" >/dev/null 2>&1 || true; }
trap 'cleanup; echo "  [cleanup] GTT $(gtt) GiB"' EXIT INT TERM
cleanup

serve(){ # model ffn gdn out
  podman run -d --rm --name "$CTR" \
    --device=/dev/kfd --device=/dev/dri --group-add keep-groups \
    --network=host -v "$MODELS":/models:z \
    -v "$REPO/config/run-kairic-serve.sh":/run.sh:ro,z --entrypoint /bin/bash \
    -e LLAMA_SERVER=/engine/llama-server \
    -e MODEL_PATH="$1" -e KAIRIC_FFN_SIDECAR="$2" \
    -e KAIRIC_GDN_SIDECAR="$3" -e KAIRIC_GDN_OUTPUT_SIDECAR="$4" \
    -e KAIRIC_EDGE_COMPATIBILITY_MODE=1 \
    -e CONTEXT=262144 -e CACHE_RAM=16384 -e KAIRIC_SLOTS=1 \
    -e KAIRIC_TEMP=0 -e KAIRIC_TOP_P=1.0 -e KAIRIC_TOP_K=0 \
    -e KAIRIC_REASONING=off -e KAIRIC_REASONING_FORMAT=deepseek \
    -e HOST=127.0.0.1 -e PORT="$PORT" \
    localhost/kairic:v1.1 /run.sh >/dev/null || return 1
  for _ in $(seq 1 300); do
    curl -sf "http://127.0.0.1:$PORT/health" >/dev/null 2>&1 && return 0
    podman inspect "$CTR" >/dev/null 2>&1 || return 1
    sleep 2
  done; return 1
}

arm(){ # label model dir prefix
  local label="$1" model="$2" dir="$3" prefix="$4"
  echo "== $label"; cleanup
  serve "$model" "$dir/$prefix-Kairic-IU4-FFN.pfs" "$dir/$prefix-Kairic-IU4-GDN.pfs" \
        "$dir/$prefix-Kairic-IU4-GDN-Output.pfs" || {
    echo "  DID NOT START"; podman logs "$CTR" 2>&1 | grep -iE 'promptforge|error' | head -5 | sed 's/^/    /'; cleanup; return; }
  podman logs "$CTR" 2>&1 | grep -oE '"record":"promptforge_init"[^}]*' | head -1 | sed 's/^/  /'
  podman logs "$CTR" 2>&1 | grep -iE 'promptforge:.*(invalid|wrong|cannot|failed)' | head -3 | sed 's/^/  /'
  local used; used=$(gtt)
  local out; out=$(python3 "$REPO/tools/concbench.py" --port "$PORT" --streams 1 --reps 5 \
        --maxtok 512 --workload humaneval --tasks "$TASKS" 2>/dev/null)
  [ -z "$out" ] && { echo "  MEASUREMENT FAILED"; cleanup; return; }
  [ -s "$OUT" ] || printf 'arm\tper_stream_tps\tspread_pct\taggregate_tps\tdraft_n\taccept_pct\tgtt_gib\n' > "$OUT"
  echo "$out" | python3 -c "
import json,sys
d=json.load(sys.stdin)
open('$OUT','a').write('\t'.join(['$label',str(d['per_stream_tps']),str(d['per_stream_spread_pct']),
  str(d['aggregate_tps']),str(d['draft_n']),str(d['draft_accept_pct']),'$used'])+'\n')
print(f\"  per-stream {d['per_stream_tps']} (+/-{d['per_stream_spread_pct']}%)  accept {d['draft_accept_pct']}  GTT ${used}GiB\")"
  if [ "${QUALITY:-0}" = 1 ]; then
    local r; r=$(python3 "$REPO/tools/humaneval_score.py" --port "$PORT" --tasks "$TASKS" \
          --limit "${LIMIT:-164}" --label "$label" 2>/dev/null | tail -1)
    [ -s "$QOUT" ] || printf 'arm\tmodel\ttasks\tpassed\tpass_at_1\n' > "$QOUT"
    echo "$r" | python3 -c "
import json,sys
d=json.load(sys.stdin)
open('$QOUT','a').write('\t'.join(['$label','$(basename "$model")',str(d['tasks']),str(d['passed']),str(d['pass_at_1'])])+'\n')
print(f\"  pass@1 {d['pass_at_1']}%  ({d['passed']}/{d['tasks']})\")"
  fi
  cleanup
}

echo "GTT before: $(gtt) GiB"
for a in $ARMS; do case "$a" in
  stock) arm stock-repacked /models/qwen3.8-kairic/Qwen3.8-27B-IU4-Kairic-Edge.gguf "$STOCK_PFS" Qwen3.8-27B ;;
  ablit) arm ablit-sidecars /models/qwen3.8-ablit-work/Qwen3.8-27B-ablit-KairicRecipe.gguf "$ABLIT_PFS" Qwen3.8-27B-ablit ;;
esac; done
echo "BENCH_DONE"
