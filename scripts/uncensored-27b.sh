#!/usr/bin/env bash
# Abliterated Qwen3.8-27B at Kairic speed, from public artifacts to a measured
# served model. Procedure: docs/uncensored-27b-replication.md.
#
# Idempotent and resumable: each step checks its output before doing work, so
# re-running after an interrupted download or pack costs nothing. No sudo; the
# one root step (GTT boot parameter) is detected and printed, as in
# setup-kairic.sh. Usage:
#
#   scripts/uncensored-27b.sh <step>      step in: prereqs images weights recipe
#                                                  pack validate bench all
set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [ -f "$REPO/.env" ]; then set -a; . "$REPO/.env"; set +a; fi
MODELS="${MODELS:-$HOME/models}"
CONVERT_IMG=localhost/qwen-convert:c49ebdbd
QUANT_IMG=localhost/rocmi4:c49ebdbd
KAIRIC_IMG=localhost/kairic:v1.1
ABLIT_REPO=huihui-ai/Huihui-Qwen3.8-27B-abliterated
STOCK_REPO=Qwen/Qwen3.8-27B
ABLIT_SRC="$MODELS/qwen3.8-ablit-src";   ABLIT_WORK="$MODELS/qwen3.8-ablit-work"
STOCK_SRC="$MODELS/qwen3.8-stock-src";   STOCK_WORK="$MODELS/qwen3.8-stock-work"
KAIRIC="$MODELS/qwen3.8-kairic"

ok(){ printf '  [+] %s\n' "$*"; }; die(){ printf '\n[FAIL] %s\n' "$*" >&2; exit 1; }
step(){ printf '\n== %s\n' "$*"; }
pyrun(){ # run a repo tool inside the converter image (numpy + gguf-py at the pinned commit)
  podman run --rm -v "$MODELS":/models:z -v "$REPO/tools":/tools:ro,z \
    --entrypoint python3 "$CONVERT_IMG" "$@"; }

prereqs(){
  step "Prerequisites"
  for c in podman curl python3 sha256sum; do command -v "$c" >/dev/null || die "$c not installed"; done
  ok "podman $(podman --version | awk '{print $3}'), python3 $(python3 --version | awk '{print $2}')"
  [ -e /dev/kfd ] || die "/dev/kfd missing: amdgpu driver not loaded"
  id -nG | tr ' ' '\n' | grep -qx render || die "not in the 'render' group; docs/privileged-steps.md"
  gtt=$(ls /sys/class/drm/card*/device/mem_info_gtt_total 2>/dev/null | head -1)
  [ -n "$gtt" ] || die "no amdgpu GTT node"
  g=$(( $(cat "$gtt") / 1073741824 )); [ "$g" -ge 90 ] || die "GTT ${g} GiB; serving needs ~50 GiB and the compaction model shares it. Raise it: docs/privileged-steps.md"
  ok "GTT ${g} GiB"
  free=$(df -BG --output=avail "$MODELS" 2>/dev/null | tail -1 | tr -dc 0-9)
  [ "${free:-0}" -ge 200 ] || die "${free:-?} GB free under $MODELS; need ~200 (weights 74, bf16 55, recipe 15, sidecars 11, and the same again for the stock validation)"
  ok "${free} GB free under $MODELS"
  podman image exists "$KAIRIC_IMG" || die "$KAIRIC_IMG missing: make kairic-setup"
  ok "$KAIRIC_IMG present"
  for f in Qwen3.8-27B-IU4-Kairic-Edge.gguf Qwen3.8-27B-Kairic-IU4-FFN.pfs; do
    [ -r "$KAIRIC/$f" ] || die "$KAIRIC/$f missing (needed for the recipe map check and validation): make kairic-setup"; done
  ok "Kairic Edge weights present"
}
images(){
  step "Images at ROCmFPX c49ebdbd"
  podman image exists "$CONVERT_IMG" && ok "$CONVERT_IMG exists" || \
    podman build -t "$CONVERT_IMG" -f "$REPO/harness/Containerfile.qwen-convert" "$REPO/harness" || die "convert image build failed"
  podman image exists "$QUANT_IMG" && ok "$QUANT_IMG exists" || \
    podman build -t "$QUANT_IMG" -f "$REPO/harness/Containerfile.rocmi4" "$REPO/harness" || die "rocmi4 image build failed"
}
weights(){
  step "Abliterated safetensors -> $ABLIT_SRC"
  if [ "$(ls "$ABLIT_SRC"/*.safetensors 2>/dev/null | wc -l)" = 18 ]; then ok "18 shards present"; else
    "$REPO/tools/hf-pardl.sh" "$ABLIT_REPO" "$ABLIT_SRC" || die "download failed"; fi
}
recipe(){
  step "bf16 GGUF and Kairic-recipe GGUF -> $ABLIT_WORK"
  if [ -s "$ABLIT_WORK/Qwen3.8-27B-ablit-KairicRecipe.gguf" ] && [ -s "$ABLIT_WORK/ablit-bf16.gguf" ]; then ok "both present"; else
    MODELS="$MODELS" "$REPO/tools/kairic-recipe/convert-and-quantise.sh" | tail -25
    [ -s "$ABLIT_WORK/Qwen3.8-27B-ablit-KairicRecipe.gguf" ] || die "recipe GGUF not produced"; fi
}
pack_one(){ # work-dir bf16-name prefix
  local pfs="$1/pfs"; mkdir -p "$pfs"
  if [ "$(stat -c%s "$pfs/$3-Kairic-IU4-FFN.pfs" 2>/dev/null)" = 8576856064 ] && \
     [ "$(stat -c%s "$pfs/$3-Kairic-IU4-GDN.pfs" 2>/dev/null)" = 2019569664 ] && \
     [ "$(stat -c%s "$pfs/$3-Kairic-IU4-GDN-Output.pfs" 2>/dev/null)" = 756953088 ]; then ok "sidecars present at $pfs"; return; fi
  pyrun /tools/pack_pfs.py "/models/${1#$MODELS/}/$2" "/models/${1#$MODELS/}/pfs" --prefix "$3" 2>&1 | grep -v 'layer .* done' || die "pack failed"
}
pack(){ step "Pack sidecars from ablit-bf16.gguf"; pack_one "$ABLIT_WORK" ablit-bf16.gguf Qwen3.8-27B-ablit; }
validate(){
  step "Validate the packer: stock bf16 -> sidecars -> diff against Kairic's published files"
  if [ "$(ls "$STOCK_SRC"/*.safetensors 2>/dev/null | wc -l)" = 18 ]; then ok "stock shards present"; else
    "$REPO/tools/hf-pardl.sh" "$STOCK_REPO" "$STOCK_SRC" || die "stock download failed"; fi
  mkdir -p "$STOCK_WORK"
  if [ -s "$STOCK_WORK/stock-bf16.gguf" ]; then ok "stock-bf16.gguf present"; else
    podman run --rm -v "$STOCK_SRC":/src-model:ro,z -v "$STOCK_WORK":/work:z "$CONVERT_IMG" \
      /src-model --outfile /work/stock-bf16.gguf --outtype bf16 2>&1 | tail -3
    [ -s "$STOCK_WORK/stock-bf16.gguf" ] || die "stock conversion failed"; fi
  pack_one "$STOCK_WORK" stock-bf16.gguf Qwen3.8-27B
  local fail=0
  for k in FFN GDN GDN-Output; do
    echo "  -- $k"
    pyrun /tools/pfs_diff.py "/models/qwen3.8-stock-work/pfs/Qwen3.8-27B-Kairic-IU4-$k.pfs" \
      "/models/qwen3.8-kairic/Qwen3.8-27B-Kairic-IU4-$k.pfs" > "$STOCK_WORK/diff-$k.txt"
    python3 - "$STOCK_WORK/diff-$k.txt" "$k" <<'PY' || fail=1
import sys,re,collections
agg=collections.defaultdict(list)
for l in open(sys.argv[1]):
    if l.startswith('header equal: False') or l.startswith('TABLE MISMATCH'): print('    '+l.strip()); sys.exit(1)
    m=re.match(r'layer\s+(\d+) kind\s+(\d+) (?:bytes [\d.]+ nibbles|exact) ([\d.]+)',l)
    if m: agg[int(m.group(2))].append(float(m.group(3)))
floor={'FFN':{10:0.9999,13:0.9999,12:0.999,15:0.998},'GDN':{20:0.98},'GDN-Output':{40:1.0,41:1.0,42:1.0}}[sys.argv[2]]
bad=0
for k,v in sorted(agg.items()):
    mn=min(v); need=floor.get(k)
    print(f'    kind {k}: {len(v)} entries, min {mn:.5f}' + ('' if need is None or mn>=need else f'  BELOW FLOOR {need}'))
    if need is not None and mn<need: bad=1
sys.exit(bad)
PY
  done
  [ $fail = 0 ] || die "packer output drifted from the published sidecars; see $STOCK_WORK/diff-*.txt"
  ok "byte-level agreement holds (FFN codes, sums; GDN-Output bit-exact; GDN qkvz >= 98%)"
}
bench(){
  step "Serve and measure (Kairic engine, compat mode, HumanEval pool, 5 repeats)"
  MODELS="$MODELS" ARMS="${ARMS:-stock ablit}" QUALITY="${QUALITY:-1}" "$REPO/tools/sidecar-bench.sh"
}
case "${1:-}" in
  prereqs) prereqs ;; images) images ;; weights) weights ;; recipe) recipe ;;
  pack) pack ;; validate) validate ;; bench) bench ;;
  all) prereqs; images; weights; recipe; pack; validate; bench ;;
  *) sed -n '2,11p' "$0"; exit 2 ;;
esac
