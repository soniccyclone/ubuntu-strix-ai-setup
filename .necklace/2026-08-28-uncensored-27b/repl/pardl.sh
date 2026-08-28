#!/usr/bin/env bash
# Ranged parallel fetch of Qwen/Qwen3.8-27B safetensors, sha256-verified against HF's LFS oids.
set -euo pipefail
DST=~/models/qwen3.8-stock-src; PARTS=32; REPO=Qwen/Qwen3.8-27B
cd "$DST"
curl -s "https://huggingface.co/api/models/$REPO?blobs=true" | python3 -c '
import json,sys
for s in json.load(sys.stdin)["siblings"]:
    n=s["rfilename"]
    if n.endswith(".safetensors") or n.endswith(".json"): print(n,s["size"],s.get("lfs",{}).get("sha256",""))' > manifest.txt
fetch_part(){ # start end out url want
  for try in 1 2 3 4 5 6; do
    curl -sSL --retry 5 --retry-all-errors -r "$1-$2" -o "$3" "$4" || true
    [ -f "$3" ] && [ "$(stat -c%s "$3")" = "$5" ] && return 0
    echo "[retry $try] $3 got $(stat -c%s "$3" 2>/dev/null || echo 0) want $5"; sleep $((try*10))
  done; return 1
}
while read -r name size sha; do
  if [ -f "$name" ] && [ "$(stat -c%s "$name")" = "$size" ]; then echo "[skip] $name"; continue; fi
  url="https://huggingface.co/$REPO/resolve/main/$name"
  if [ -z "$sha" ]; then curl -sSL -o "$name" "$url"; echo "[done] $name"; continue; fi
  chunk=$(( (size + PARTS - 1) / PARTS ))
  for i in $(seq 0 $((PARTS-1))); do
    s=$((i*chunk)); e=$(( (i+1)*chunk - 1 )); [ $e -ge $size ] && e=$((size-1))
    fetch_part "$s" "$e" "$name.part$i" "$url" $((e-s+1)) &
  done; wait
  for i in $(seq 0 $((PARTS-1))); do [ -f "$name.part$i" ] || { echo "[FAIL] missing part $i of $name"; exit 1; }; done
  cat $(for i in $(seq 0 $((PARTS-1))); do echo "$name.part$i"; done) > "$name.tmp"; rm -f "$name".part*
  got=$(sha256sum "$name.tmp" | cut -d' ' -f1)
  if [ "$got" != "$sha" ]; then echo "[FAIL] $name sha mismatch $got"; rm -f "$name.tmp"; exit 1; fi
  mv "$name.tmp" "$name"; echo "[done] $name $(date +%T)"
done < manifest.txt
echo ALL_DONE
