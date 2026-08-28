#!/usr/bin/env bash
# ROCmI4 against Kairic Edge, on this machine, same harness as the last cycle.
#
# The question this answers: does cafonez's reported 44.39 tok/s (full HumanEval,
# W4A4) reproduce here, and how does it sit against the Kairic contract this
# repository already runs? If it does not reproduce, the whole uncensored plan
# changes before any weights get converted.
#
# READ-ONLY WITH RESPECT TO THE EXISTING SETUP. Kairic is launched the same way
# bench/parallel-sweep.sh launches it -- the shipped runner mounted read-only
# into a throwaway container. Nothing in config/, systemd/ or the installed unit
# is written. The ROCmI4 arm uses a different image, port, and model directory.
#
# Both arms use tools/concbench.py: same HumanEval pool of 8, five repeats, one
# warming pass discarded, greedy, 512-token cap. The noise floor here is ~13%
# peak-to-peak, so every figure carries its spread and five is the floor.
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
CTR=i4probe
PORT=8090
OUT="${OUT:-$(dirname "$0")/rocmi4-vs-kairic.tsv}"
REPS="${REPS:-5}"
MAXTOK="${MAXTOK:-512}"
TASKS="$REPO/.necklace/2026-08-22-qwen38-27b/repl/humaneval.jsonl"
HARNESS="$REPO/tools/concbench.py"
MODELS="${MODELS:-$HOME/models}"
I4=/models/qwen3.8-rocmi4
K=/models/qwen3.8-kairic

gtt(){ echo $(( $(cat /sys/class/drm/card1/device/mem_info_gtt_used) / 1073741824 )); }
cleanup(){ podman rm -f "$CTR" >/dev/null 2>&1 || true; }
trap 'cleanup; echo "  [cleanup] GTT $(gtt) GiB"' EXIT INT TERM
cleanup

wait_health(){ for _ in $(seq 1 240); do
    curl -sf "http://127.0.0.1:$PORT/health" >/dev/null 2>&1 && return 0
    podman inspect "$CTR" >/dev/null 2>&1 || return 1
    sleep 2
  done; return 1; }

# --- ROCmI4, at the publisher's own launch flags ---------------------------
start_rocmi4(){
  podman run -d --rm --name "$CTR" \
    --device=/dev/kfd --device=/dev/dri --group-add keep-groups \
    --network=host -v "$MODELS":/models:z \
    -e HIP_VISIBLE_DEVICES=0 -e HSA_OVERRIDE_GFX_VERSION=11.5.1 \
    localhost/rocmi4:c49ebdbd \
    -m $I4/Qwen3.8-27B-Q4_0_ROCMI4.gguf \
    --host 127.0.0.1 --port "$PORT" --alias qwen38-27b-rocmi4 \
    -dev ROCm0 -ngl 999 -np 1 -c 262144 \
    -b 512 -ub 256 -t 16 -tb 32 -fa on \
    -ctk f16 -ctv f16 --jinja \
    --spec-type draft-mtp --spec-mtp-strict-qwen \
    --spec-draft-device ROCm0 --spec-draft-ngl all \
    --spec-draft-type-k f16 --spec-draft-type-v f16 \
    --spec-draft-n-max 16 --spec-draft-n-min 0 \
    --spec-draft-p-min 0.60 --spec-draft-backend-sampling \
    --reasoning off --reasoning-format deepseek >/dev/null
}

# --- Kairic, exactly as this repository already serves it -------------------
start_kairic(){
  podman run -d --rm --name "$CTR" \
    --device=/dev/kfd --device=/dev/dri --group-add keep-groups \
    --network=host -v "$MODELS":/models:z \
    -v "$REPO/config/run-kairic-serve.sh":/run.sh:ro,z --entrypoint /bin/bash \
    -e LLAMA_SERVER=/engine/llama-server \
    -e MODEL_PATH=$K/Qwen3.8-27B-IU4-Kairic-Edge.gguf \
    -e KAIRIC_FFN_SIDECAR=$K/Qwen3.8-27B-Kairic-IU4-FFN.pfs \
    -e KAIRIC_GDN_SIDECAR=$K/Qwen3.8-27B-Kairic-IU4-GDN.pfs \
    -e KAIRIC_GDN_OUTPUT_SIDECAR=$K/Qwen3.8-27B-Kairic-IU4-GDN-Output.pfs \
    -e KAIRIC_EDGE_COMPATIBILITY_MODE=1 \
    -e CONTEXT=262144 -e CACHE_RAM=16384 -e KAIRIC_SLOTS=1 \
    -e KAIRIC_TEMP=0 -e KAIRIC_TOP_P=1.0 -e KAIRIC_TOP_K=0 \
    -e KAIRIC_REASONING=off -e KAIRIC_REASONING_FORMAT=deepseek \
    -e HOST=127.0.0.1 -e PORT="$PORT" \
    localhost/kairic:v1.1 /run.sh >/dev/null
}

arm(){ # label starter
  printf '%-16s ' "$1"
  cleanup
  $2 || { echo "LAUNCH FAILED"; return; }
  if ! wait_health; then
    echo "DID NOT START"
    podman logs "$CTR" 2>&1 | grep -iE 'error|unknown|unsupported' | head -3 | sed 's/^/    /'
    cleanup; return
  fi
  # The accelerated path is opt-in at build time and announced at startup.
  # Believe the banner, not the flags.
  local w4a4 used out
  w4a4=$(podman logs "$CTR" 2>&1 | grep -oiE 'ROCmI4 W4A4: *[a-z]+' | head -1)
  used=$(gtt)
  out=$(python3 "$HARNESS" --port "$PORT" --streams 1 --reps "$REPS" \
          --maxtok "$MAXTOK" --workload humaneval --tasks "$TASKS" 2>/dev/null)
  [ -z "$out" ] && { echo "MEASUREMENT FAILED"; cleanup; return; }
  echo "$out" | python3 -c "
import json,sys
d=json.load(sys.stdin)
row=['$1',str(d['per_stream_tps']),str(d['per_stream_spread_pct']),
     str(d['aggregate_tps']),str(d['aggregate_spread_pct']),
     str(d['draft_n']),str(d['draft_accept_pct'] if d['draft_accept_pct'] is not None else ''),
     '$used','${w4a4:-n/a}','measured on this box']
open('$OUT','a').write('\t'.join(row)+'\n')
print(f\"per-stream {d['per_stream_tps']:>6} (+/-{d['per_stream_spread_pct']}%)  \"
      f\"accept {d['draft_accept_pct']}  GTT ${used}GiB  ${w4a4:-}\")"
  cleanup
}

[ -s "$OUT" ] || printf 'arm\tper_stream_tps\tper_stream_spread_pct\taggregate_tps\taggregate_spread_pct\tdraft_n\tdraft_accept_pct\tgtt_gib\tw4a4\tprovenance\n' > "$OUT"
echo "GTT before: $(gtt) GiB"
arm "rocmi4-pub"  start_rocmi4
arm "kairic-ref"  start_kairic
echo; echo "wrote $OUT"
