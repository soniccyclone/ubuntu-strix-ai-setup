#!/usr/bin/env bats
# CUJ-05 — a stated face budget is honoured, and its cost is visible.

FIX=tests/fixtures
REC=bench/media-timings.tsv

setup_file() {
  curl -sf -m 10 http://127.0.0.1:8189/health >/dev/null \
    || { echo "media-engine not answering" >&2; return 1; }
}

@test "a stated face target is honoured" {
  out=/tmp/budget-$$.glb
  run python3 tools/mesh.py "$FIX/warrior-1024.png" "$out" --resolution 512 --target-faces 8000 --seed 71
  [ "$status" -eq 0 ]
  tri=$(python3 tools/glbinfo.py "$out" | jq -r .triangles)
  rm -f "$out"
  # Decimation lands near the target rather than exactly on it: measured 11,568
  # for a target of 12,000. Allow 25% either side, which still catches a target
  # being ignored entirely.
  awk -v t="$tri" 'BEGIN{exit !(t > 6000 && t < 10000)}'
}

@test "the cost of a face target is recorded, not hidden" {
  # A smaller target costs MORE, because the work is in the decimation and it
  # has further to go. That is counterintuitive enough that the record has to
  # carry it or someone will pick the cheap-sounding setting.
  [ -f "$REC" ]
  head -1 "$REC" | grep -q "target_faces"
  head -1 "$REC" | grep -q "seconds"
  # At least two rows at differing targets, so the comparison is present.
  targets=$(awk -F'\t' 'NR>1 && $0 ~ /mesh/ {print $6}' "$REC" | sort -u | wc -l)
  [ "$targets" -ge 2 ]
}
