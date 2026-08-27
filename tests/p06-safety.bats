#!/usr/bin/env bats
# CUJ-06 — the sweep holds a known amount, refuses without headroom, releases it.
#
# This repository has already paid for getting this wrong: a resident model and
# a parallel build together took the machine down, and total process RSS read
# 40 GiB while 122 GiB was exhausted. On a unified-memory APU the weights live
# in GTT and no process-level tool reports them.

SWEEP=bench/parallel-sweep.sh

@test "the sweep reads GPU memory, not process memory" {
  [ -x "$SWEEP" ]
  # Headroom must come from the amdgpu GTT node. ps/top/podman stats report a
  # 47 GiB model as approximately nothing.
  grep -q 'mem_info_gtt_used' "$SWEEP"
  grep -q 'mem_info_gtt_total' "$SWEEP"
  # Strip comments first: the header explains why podman stats and RSS are the
  # wrong sources, so a naive grep matches the explanation and fails the file
  # that gets it right.
  run bash -c "grep -vE '^[[:space:]]*#' '$SWEEP' | grep -cE 'podman stats|ps -eo|--format .*MemUsage'"
  [ "$output" = "0" ]
}

@test "the sweep refuses to start an arm without headroom" {
  [ -x "$SWEEP" ]
  # Demand more headroom than the machine could possibly have.
  run env SWEEP_MIN_FREE_GIB=999999 SWEEP_DRY_RUN=1 "$SWEEP"
  [ "$status" -ne 0 ]
  # It has to say what it wanted and what it found, not just fail.
  [[ "$output" == *"999999"* ]]
  [[ "$output" == *"GiB"* ]]
}

@test "the sweep stops its container on interrupt" {
  [ -x "$SWEEP" ]
  # A trap that only fires on clean exit is the failure mode that leaves 47 GiB
  # resident after Ctrl-C. Assert all three signals plus EXIT.
  run grep -E '^\s*trap .* EXIT' "$SWEEP"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q 'INT'
  echo "$output" | grep -q 'TERM'
  # And the trap must actually remove the container, not merely echo.
  echo "$output" | grep -qE 'cleanup|podman rm'
}

@test "the sweep names its own container so a stray one is findable" {
  [ -x "$SWEEP" ]
  # --name, not a podman-assigned random word: `make stop-all` and a human
  # looking for a leak both need a predictable handle.
  grep -qE '\-\-name "?\$\{?CTR' "$SWEEP"
  grep -qE '^CTR=' "$SWEEP"
}
