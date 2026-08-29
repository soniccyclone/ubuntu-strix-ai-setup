#!/usr/bin/env bash
# Abliterated safetensors -> GGUF (MTP kept) -> Kairic's mixed-precision recipe.
#
# The point of the exercise: Kairic's speed may come mostly from its base
# quantisation rather than its unpublished IU4 sidecars. Its per-tensor
# assignment is extractable from the GGUF on this disk, and the fork's quantiser
# takes --tensor-type-file. So the recipe can be applied to other weights even
# though the sidecars cannot be rebuilt.
#
# The name check between conversion and quantisation is not a formality. The map
# is keyed on GGUF names; the source is safetensors. If this converter names
# anything differently from whatever produced Kairic's GGUF, the map silently
# fails to apply to those tensors and they quietly stay at the default type --
# which would look like a disappointing result rather than a broken run.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="${SRC:-$HOME/models/qwen3.8-ablit-src}"
WORK="${WORK:-$HOME/models/qwen3.8-ablit-work}"
MAP="$HERE/kairic-precision-map.json"
BF16="$WORK/ablit-bf16.gguf"
OUT="$WORK/Qwen3.8-27B-ablit-KairicRecipe.gguf"
TT="$WORK/tensor-types.txt"
mkdir -p "$WORK"

step(){ printf '\n== %s\n' "$*"; }

step "convert to GGUF, MTP retained"
if [ -s "$BF16" ]; then echo "  already converted"; else
  podman run --rm -v "$SRC":/src-model:ro,z -v "$WORK":/work:z \
    localhost/qwen-convert:c49ebdbd \
    /src-model --outfile /work/ablit-bf16.gguf --outtype bf16 \
    2>&1 | tail -20
  [ -s "$BF16" ] || { echo "  CONVERSION FAILED"; exit 1; }
fi
echo "  $(du -h "$BF16" | cut -f1)"

step "check the map's names against the converted file"
python3 "$HERE/check-map-names.py" "$BF16" "$MAP" "$TT" || {
  echo "  NAME MISMATCH -- stopping before quantise"; exit 1; }

step "quantise to Kairic's recipe"
podman run --rm -v "$WORK":/work:z --entrypoint /engine/llama-quantize \
  localhost/rocmi4:c49ebdbd \
  --tensor-type-file /work/tensor-types.txt \
  --output-tensor-type q8_0 --token-embedding-type q6_k \
  /work/ablit-bf16.gguf "/work/$(basename "$OUT")" Q4_0_ROCMFP4 "$(nproc)" \
  2>&1 | tail -15
[ -s "$OUT" ] && echo "  wrote $(du -h "$OUT" | cut -f1)" || { echo "  QUANTISE FAILED"; exit 1; }

step "verify the result carries the intended precision mix"
python3 "$HERE/extract-precision-map.py" "$OUT"
echo "CONVERT_QUANTISE_DONE"
