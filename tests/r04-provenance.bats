#!/usr/bin/env bats
# CUJ-04 — a stranger arriving from the benchmark traces each number to the
# upstream that produced it.
#
# The two engines in the headline comparison are different people's forks of
# ROCmFPX, kept as separate images on purpose. That was explained only in
# harness/Containerfile.kairic, which nobody reading a throughput table opens.

DOC=docs/kairic-edge-opencode.md

@test "every engine in the headline comparison names its upstream" {
  # The README's comparison must lead somewhere that names both upstreams.
  grep -q '41.89' README.md
  grep -q '22.21' README.md
  [ -f "$DOC" ]
  grep -qE '^#+ .*[Uu]pstream' "$DOC"
  grep -q 'github.com/ciru-ai/ROCmFPX' "$DOC"
  grep -q 'github.com/charlie12345/ROCmFPX' "$DOC"
}

@test "the two engines are recorded as separate forks on purpose" {
  # Not merely both listed: a reader has to learn they are different forks and
  # why one image cannot serve both.
  run bash -c "sed -n '/^#\+ .*[Uu]pstream/,/^#\+ [^U]/p' '$DOC'"
  [ "$status" -eq 0 ]
  echo "$output" | grep -qi 'fork'
  echo "$output" | grep -qi 'composable kernel'
}

@test "the upstream a Containerfile clones matches the one documented" {
  # If a Containerfile is repointed at a different fork, the documentation must
  # move with it rather than silently describing the wrong engine.
  for cf in harness/Containerfile.kairic harness/Containerfile.rocmfpx harness/Containerfile.rocmfpx-hip; do
    [ -f "$cf" ]
    for url in $(grep -oE 'https://github\.com/[A-Za-z0-9._-]+/ROCmFPX(\.git)?' "$cf" | sed 's/\.git$//' | sort -u); do
      grep -qF "$url" "$DOC"
    done
  done
}
