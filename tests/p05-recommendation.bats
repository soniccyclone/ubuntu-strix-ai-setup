#!/usr/bin/env bats
# CUJ-05 — a recommended slot count, with the evidence for it.
#
# Nathan's call for this cycle: measure and recommend, do not change what ships.
# A slot count cannot move without opencode's context limit moving with it, and
# that pairing is a decision rather than a consequence of a table.

WRITEUP="${WRITEUP:-docs/parallel-scaling.md}"
YAML=config/llama-swap-kairic.yaml
RUNNER=config/run-kairic-serve.sh
CLIENT=config/opencode-kairic.jsonc

@test "the writeup states a recommended slot count" {
  [ -f "$WRITEUP" ]
  run grep -icE 'recommend' "$WRITEUP"
  [ "$output" -ge 1 ]
  # A recommendation that does not name a number is not one.
  grep -qE 'recommend[^.]*(one|two|four|eight|1|2|4|8) slot' "$WRITEUP"
}

@test "the recommendation cites both throughput and context cost" {
  [ -f "$WRITEUP" ]
  # Slots are bought with context here, so a throughput-only recommendation is
  # incomplete regardless of which way the numbers pointed.
  run bash -c "grep -iA12 'recommend' '$WRITEUP' | grep -ci 'tok/s'"
  [ "$output" -ge 1 ]
  run bash -c "grep -iA12 'recommend' '$WRITEUP' | grep -ciE 'context|window|per-slot'"
  [ "$output" -ge 1 ]
}

@test "the shipped slot count is unchanged by this cycle" {
  # This cycle measures and recommends. If it moved the default, it did so
  # without the client change that must accompany it.
  local slots
  slots=$(grep -oE 'KAIRIC_SLOTS:-[0-9]+' "$RUNNER" | grep -oE '[0-9]+$' | head -1)
  [ "$slots" = "2" ]
}

@test "the shipped client context is unchanged by this cycle" {
  local got
  got=$(python3 -c "
import json,re
raw=re.sub(r'^\s*//.*$','',open('$CLIENT').read(),flags=re.M)
print(json.loads(raw)['provider']['contract']['models']['code']['limit']['context'])")
  [ "$got" = "131072" ]
}
