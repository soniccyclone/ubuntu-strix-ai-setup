#!/usr/bin/env bats
# CUJ-04 — what raising slots costs in per-slot context.
#
# -c is TOTAL across slots, not per slot: -c 8192 -np 2 gives each slot
# n_ctx 4096. So slots are bought with context, and the client's declared window
# has to move whenever the slot count does.

REC="${REC:-bench/parallel-scaling.tsv}"
YAML=config/llama-swap-kairic.yaml
RUNNER=config/run-kairic-serve.sh
CLIENT=config/opencode-kairic.jsonc
WRITEUP="${WRITEUP:-docs/parallel-scaling.md}"

# How many arms the sweep actually plans. Hardcoding this drifted once
# already: the guard said 13 after an arm was dropped to 12.
expected_arms() { grep -cE '^\s+"np[0-9]' bench/parallel-sweep.sh; }

rows() { tail -n +2 "$REC" | grep -c . ; }
col()  { head -1 "$REC" | tr '\t' '\n' | grep -nx "$1" | cut -d: -f1; }

@test "every slot count in the record names its per-slot context window" {
  [ -f "$REC" ]
  [ "$(rows)" -ge "$(expected_arms)" ]
  local t p s
  t=$(col ctx_total); p=$(col ctx_per_slot); s=$(col slots)
  run awk -F'\t' -v t="$t" -v p="$p" -v s="$s" \
      'NR>1 && ($p=="" || $p+0 != int($t/$s)){c++} END{print c+0}' "$REC"
  [ "$output" = "0" ]
}

@test "the coding model's declared context equals the per-slot window" {
  # opencode declares TWO contexts: code at 131072 and compact at 262144. Only
  # 'code' pairs with the slot count, so a test that scans every declared limit
  # is satisfied by 'compact' no matter what 'code' says.
  local ctx slots want got
  ctx=$(grep -oE '^\s+-e CONTEXT=[0-9]+' "$YAML" | grep -oE '[0-9]+$' | head -1)
  slots=$(grep -oE 'KAIRIC_SLOTS:-[0-9]+' "$RUNNER" | grep -oE '[0-9]+$' | head -1)
  [ -n "$ctx" ] && [ -n "$slots" ]
  want=$(( ctx / slots ))
  got=$(python3 -c "
import json,re,sys
raw=open('$CLIENT').read()
raw=re.sub(r'^\s*//.*$','',raw,flags=re.M)
d=json.loads(raw)
print(d['provider']['contract']['models']['code']['limit']['context'])")
  [ "$got" -eq "$want" ]
}

@test "the writeup names the client setting that moves with slots" {
  [ -f "$WRITEUP" ]
  # Naming a slot count without naming what else must change is how someone
  # ends up with a client declaring twice the window it actually has.
  grep -q 'limit.context\|limit"\?: *{ *"context' "$WRITEUP"
  grep -qi 'opencode' "$WRITEUP"
}

@test "the writeup states what a coding agent is left to work in" {
  [ -f "$WRITEUP" ]
  # opencode reserves 24576 for compaction. At eight slots a slot holds 32768,
  # so the number that matters is what remains, not the window.
  grep -q '24576\|compaction reserve' "$WRITEUP"
  grep -q '32768' "$WRITEUP"
}
