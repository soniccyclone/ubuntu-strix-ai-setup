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

@test "the shipped slot count is the one the writeup recommends" {
  # Pinning a literal broke the moment the recommendation changed, which is the
  # wrong shape for this: what must hold is that the shipped configuration and
  # the published recommendation agree, whichever number they settle on.
  local recommended slots
  recommended=$(grep -oiE 'recommends (one|two|four|eight|[0-9]+) slot' "$WRITEUP" \
                | head -1 | grep -oiE '(one|two|four|eight|[0-9]+)')
  [ -n "$recommended" ]
  case "$(echo "$recommended" | tr 'A-Z' 'a-z')" in
    one) recommended=1 ;; two) recommended=2 ;;
    four) recommended=4 ;; eight) recommended=8 ;;
  esac
  slots=$(grep -oE 'KAIRIC_SLOTS:-[0-9]+' "$RUNNER" | grep -oE '[0-9]+$' | head -1)
  [ "$slots" = "$recommended" ]
}

@test "no client model pins a slot the server does not have" {
  # code-sub used to pin id_slot 1. At one slot that slot does not exist, and a
  # request pinned to it is a failure nobody would trace back to this file.
  local slots
  slots=$(grep -oE 'KAIRIC_SLOTS:-[0-9]+' "$RUNNER" | grep -oE '[0-9]+$' | head -1)
  run python3 -c "
import json,re,sys
raw=re.sub(r'^\s*//.*$','',open('$CLIENT').read(),flags=re.M)
d=json.loads(raw)
bad=[n for n,m in d['provider']['contract']['models'].items()
     if (m.get('options',{}).get('id_slot') or 0) >= $slots]
print(','.join(bad))"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}
