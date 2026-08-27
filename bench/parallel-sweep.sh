#!/usr/bin/env bash
# Concurrent-slot sweep for Kairic Edge: does aggregate throughput scale, and
# does MTP speculation still pay once it does?
#
# Thirteen arms, ~47 GiB resident each, roughly an hour. Memory does not grow
# with slot count -- -c is TOTAL across slots, so the KV allocation is fixed and
# the slots divide it. Measured 47/47/46 GiB at -np 1/2/8.
#
# HEADROOM IS READ FROM GTT, NOT FROM PROCESS MEMORY. On this unified-memory APU
# the weights live in GTT and ps, top and podman stats all report a 47 GiB model
# as approximately nothing. This repository has already had the machine taken
# down by trusting RSS; see .necklace/2026-08-19-local-claude-suite/ledger.md.
#
# Every arm stops its own container from a trap on EXIT, INT and TERM, so an
# abort at any point still leaves the machine clean.
#
#   bench/parallel-sweep.sh                  run the sweep
#   SWEEP_DRY_RUN=1 bench/parallel-sweep.sh  print the arm plan, launch nothing
#   SWEEP_ARMS=main bench/parallel-sweep.sh  run one group only
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CTR=kairic-sweep
PORT="${SWEEP_PORT:-8085}"
OUT="${SWEEP_OUT:-$REPO/bench/parallel-scaling.tsv}"
REPS="${SWEEP_REPS:-5}"
MAXTOK="${SWEEP_MAXTOK:-512}"
TASKS="$REPO/.necklace/2026-08-22-qwen38-27b/repl/humaneval.jsonl"
RUNNER="$REPO/.necklace/2026-08-26-parallel-scaling/repl/run-kairic-serve-spec.sh"
HARNESS="$REPO/tools/concbench.py"
K=/models/qwen3.8-kairic
MODELS="${MODELS:-$HOME/models}"

# The model needs ~47 GiB. Refuse below this rather than compete with whatever
# else is on the machine -- it acquires work without announcing itself.
MIN_FREE_GIB="${SWEEP_MIN_FREE_GIB:-60}"

cleanup(){ podman rm -f "$CTR" >/dev/null 2>&1 || true; }
trap 'cleanup' EXIT INT TERM

gtt_used(){  local f; f=$(ls /sys/class/drm/card*/device/mem_info_gtt_used  2>/dev/null | head -1); [ -n "$f" ] && echo $(( $(cat "$f") / 1073741824 )) || echo 0; }
gtt_total(){ local f; f=$(ls /sys/class/drm/card*/device/mem_info_gtt_total 2>/dev/null | head -1); [ -n "$f" ] && echo $(( $(cat "$f") / 1073741824 )) || echo 0; }
gtt_free(){  echo $(( $(gtt_total) - $(gtt_used) )); }

require_headroom(){
  local free; free=$(gtt_free)
  if [ "$free" -lt "$MIN_FREE_GIB" ]; then
    echo "[REFUSED] need ${MIN_FREE_GIB} GiB of GTT free, found ${free} GiB ($(gtt_used) GiB in use of $(gtt_total) total)" >&2
    return 1
  fi
  return 0
}

# arm: label group slots ctx cache_ram spec workload
ARMS=(
  "np1-mtp         main    1 262144 16384 draft-mtp humaneval"
  "np1-nomtp       main    1 262144 16384 none      humaneval"
  "np2-mtp         main    2 262144 16384 draft-mtp humaneval"
  "np2-nomtp       main    2 262144 16384 none      humaneval"
  "np4-mtp         main    4 262144 16384 draft-mtp humaneval"
  "np4-nomtp       main    4 262144 16384 none      humaneval"
  "np8-mtp         main    8 262144 16384 draft-mtp humaneval"
  "np8-nomtp       main    8 262144 16384 none      humaneval"
  "np1-win32k-mtp  window  1  32768 16384 draft-mtp humaneval"
  "np1-cache8192   cache   1 262144  8192 draft-mtp humaneval"
  "np8-prose-mtp   prose   8 262144 16384 draft-mtp prose"
  "np8-prose-nomtp prose   8 262144 16384 none      prose"
)

plan(){
  printf '%-18s %-7s %6s %8s %7s %-10s %s\n' label group slots ctx cache spec workload
  local l g s c r sp w
  for a in "${ARMS[@]}"; do
    read -r l g s c r sp w <<<"$a"
    [ -n "${SWEEP_ARMS:-}" ] && [ "$g" != "$SWEEP_ARMS" ] && continue
    printf '%-18s %-7s %6s %8s %7s %-10s %s\n' "$l" "$g" "$s" "$c" "$r" "$sp" "$w"
  done
}

start_arm(){ # slots ctx cache spec
  podman run -d --rm --name "$CTR" \
    --device=/dev/kfd --device=/dev/dri --group-add keep-groups \
    --network=host -v "$MODELS":/models:z \
    -v "$RUNNER":/run.sh:ro,z --entrypoint /bin/bash \
    -e LLAMA_SERVER=/engine/llama-server \
    -e MODEL_PATH=$K/Qwen3.8-27B-IU4-Kairic-Edge.gguf \
    -e KAIRIC_FFN_SIDECAR=$K/Qwen3.8-27B-Kairic-IU4-FFN.pfs \
    -e KAIRIC_GDN_SIDECAR=$K/Qwen3.8-27B-Kairic-IU4-GDN.pfs \
    -e KAIRIC_GDN_OUTPUT_SIDECAR=$K/Qwen3.8-27B-Kairic-IU4-GDN-Output.pfs \
    -e KAIRIC_EDGE_COMPATIBILITY_MODE=1 \
    -e CONTEXT="$2" -e CACHE_RAM="$3" \
    -e KAIRIC_SLOTS="$1" -e KAIRIC_SPEC_TYPE="$4" \
    -e KAIRIC_TEMP=0 -e KAIRIC_TOP_P=1.0 -e KAIRIC_TOP_K=0 \
    -e KAIRIC_REASONING=off -e KAIRIC_REASONING_FORMAT=none \
    -e HOST=127.0.0.1 -e PORT="$PORT" \
    localhost/kairic:v1.1 /run.sh >/dev/null || return 1
  for _ in $(seq 1 240); do
    curl -sf "http://127.0.0.1:$PORT/health" >/dev/null 2>&1 && return 0
    podman inspect "$CTR" >/dev/null 2>&1 || return 1
    sleep 2
  done
  return 1
}

main(){
  [ -r "$TASKS" ]   || { echo "[FAIL] no humaneval.jsonl at $TASKS" >&2; exit 2; }
  [ -r "$RUNNER" ]  || { echo "[FAIL] no runner at $RUNNER" >&2; exit 2; }
  [ -r "$HARNESS" ] || { echo "[FAIL] no harness at $HARNESS" >&2; exit 2; }

  echo "== arm plan"
  plan
  echo
  echo "GTT: $(gtt_used) GiB used of $(gtt_total), $(gtt_free) free; refusing below ${MIN_FREE_GIB}"
  require_headroom || exit 1

  if [ -n "${SWEEP_DRY_RUN:-}" ]; then
    echo "[dry run] nothing launched"
    exit 0
  fi

  if [ ! -s "$OUT" ]; then
    printf 'label\tgroup\tslots\tctx_total\tctx_per_slot\tcache_ram\tspec_type\tspec_impls\tworkload\tpool\treps\tper_stream_tps\tper_stream_spread_pct\taggregate_tps\taggregate_spread_pct\tdraft_n\tdraft_accept_pct\tgtt_gib\tprovenance\n' > "$OUT"
  fi

  local l g s c r sp w
  for a in "${ARMS[@]}"; do
    read -r l g s c r sp w <<<"$a"
    [ -n "${SWEEP_ARMS:-}" ] && [ "$g" != "$SWEEP_ARMS" ] && continue

    printf '%-18s ' "$l"
    require_headroom || { echo "skipped, no headroom"; continue; }

    if ! start_arm "$s" "$c" "$r" "$sp"; then
      echo "FAILED TO START"
      podman logs "$CTR" 2>&1 | grep -iE 'error|invalid|unrecognized' | head -3 | sed 's/^/    /'
      cleanup; continue
    fi

    local slot_ctx used out impls
    slot_ctx=$(podman logs "$CTR" 2>&1 | grep -oE 'new slot, n_ctx = [0-9]+' | head -1 | grep -oE '[0-9]+$')
    used=$(gtt_used)
    # --spec-type selects what JOINS the kairic-edge default stack, not whether
    # speculation happens: with "none" the server still loads ngram-mod, which
    # drafts freely on code and not at all on prose. Record what it actually
    # initialised so an arm cannot be quietly wrong about what it ran.
    impls=$(podman logs "$CTR" 2>&1 \
            | grep -oE "adding speculative implementation '[a-z0-9-]+'" \
            | grep -oE "'[a-z0-9-]+'" | tr -d "'" | sort -u | paste -sd+ -)
    impls="${impls:-none-loaded}"

    local wl_args=(--workload "$w")
    [ "$w" = "humaneval" ] && wl_args+=(--tasks "$TASKS")

    out=$(python3 "$HARNESS" --port "$PORT" --streams "$s" --reps "$REPS" \
            --maxtok "$MAXTOK" "${wl_args[@]}" 2>/dev/null)
    if [ -z "$out" ]; then
      echo "MEASUREMENT FAILED"; cleanup; continue
    fi

    echo "$out" | python3 -c "
import json,sys
d=json.load(sys.stdin)
row=['$l','$g','$s','$c','${slot_ctx:-}','$r','$sp','$impls','$w',str(d['pool']),str(d['reps']),
     str(d['per_stream_tps']),str(d['per_stream_spread_pct']),
     str(d['aggregate_tps']),str(d['aggregate_spread_pct']),
     str(d['draft_n']),str(d['draft_accept_pct'] if d['draft_accept_pct'] is not None else ''),
     '$used','measured on this box']
open('$OUT','a').write('\t'.join(row)+'\n')
print(f\"per-stream {d['per_stream_tps']:>6} (+/-{d['per_stream_spread_pct']}%)  \"
      f\"aggregate {d['aggregate_tps']:>7} (+/-{d['aggregate_spread_pct']}%)  \"
      f\"accept {d['draft_accept_pct']}  slot_ctx ${slot_ctx:-?}  GTT ${used}GiB\")"
    cleanup
  done

  echo
  echo "wrote $OUT"
  echo "GTT after: $(gtt_used) GiB used, $(gtt_free) free"
}

main "$@"
