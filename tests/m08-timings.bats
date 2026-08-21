#!/usr/bin/env bats
# CUJ-08 — a future maintainer reproduces the timings.

REC=bench/media-timings.tsv

@test "every row names model, precision, resolution and residency" {
  # A bare duration is not reproducible: cold and warm differ 3x on the image
  # stage, and a smaller face target is SLOWER on the mesh stage.
  [ -f "$REC" ]
  hdr=$(head -1 "$REC")
  for col in stage model precision resolution residency target_faces seconds; do
    grep -q "$col" <<<"$hdr"
  done
  # No row may leave a mandatory field empty.
  run awk -F'\t' 'NR>1 { for(i=1;i<=7;i++) if($i=="") { print "row "NR" col "i" empty"; bad=1 } } END{ exit bad?1:0 }' "$REC"
  [ "$status" -eq 0 ]
}

@test "the record distinguishes this box from cited references" {
  # Half these numbers are other people's. A row that does not say so invites
  # someone to treat a citation as a measurement.
  mine=$(awk -F'\t' 'NR>1 && $8 ~ /this box/' "$REC" | wc -l)
  cited=$(awk -F'\t' 'NR>1 && ($8 ~ /published/ || $8 ~ /reference/)' "$REC" | wc -l)
  [ "$mine" -ge 5 ]
  [ "$cited" -ge 3 ]
}

@test "the image harness varies the seed between runs" {
  # An identical graph returns the previous result in about a second without
  # executing anything, and that nearly became a finding.
  grep -q "def reseed" tools/imgbench.py
  grep -q "reseed(graph, i)" tools/imgbench.py
}

@test "recording a timing requires the fields that make it reproducible" {
  run python3 tools/record_timing.py --stage image --model X --precision fp8 --resolution 512
  [ "$status" -ne 0 ]
  [[ "$output" == *"residency"* || "$output" == *"required"* ]]
}
