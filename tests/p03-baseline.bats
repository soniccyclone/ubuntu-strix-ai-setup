#!/usr/bin/env bats
# CUJ-03 — whether the published 41.89 still holds, and what moved it.
#
# Nathan posted that figure hedging he had not vetted it. Under its own
# conditions this machine measured 46-49 tok/s hot with acceptance at 76.2%,
# the published value exactly. The leading explanation is that the run behind it
# used --cache-ram 8192 where the shipped config now uses 16384 -- which makes
# the figure stale rather than wrong. That is a hypothesis until the A/B runs.

REC="${REC:-bench/parallel-scaling.tsv}"
WRITEUP="${WRITEUP:-docs/parallel-scaling.md}"
# How many arms the sweep actually plans. Hardcoding this drifted once
# already: the guard said 13 after an arm was dropped to 12.
expected_arms() { grep -cE '^\s+"np[0-9]' bench/parallel-sweep.sh; }

rows() { tail -n +2 "$REC" | grep -c . ; }
col()  { head -1 "$REC" | tr '\t' '\n' | grep -nx "$1" | cut -d: -f1; }

@test "the single-slot arm records the conditions the published figure was taken under" {
  [ -f "$REC" ]
  [ "$(rows)" -ge "$(expected_arms)" ]
  # Greedy, 512 cap, reasoning off, hot cache, HumanEval. A row that does not
  # carry its conditions cannot be compared with anything.
  local line
  line=$(awk -F'\t' '$1=="np1-mtp"' "$REC")
  [ -n "$line" ]
  echo "$line" | grep -q 'humaneval'
  echo "$line" | grep -q '262144'
  echo "$line" | grep -q '16384'
  # And the sampling and warmth live in the harness, which the record points at.
  grep -q 'temperature": 0' tools/concbench.py
  grep -q 'warm' tools/concbench.py
}

@test "draft acceptance on the single-slot arm lands in the published regime" {
  [ -f "$REC" ]
  [ "$(rows)" -ge "$(expected_arms)" ]
  local a acc
  a=$(col draft_accept_pct)
  acc=$(awk -F'\t' -v a="$a" '$1=="np1-mtp"{print $a}' "$REC")
  [ -n "$acc" ]
  # Published is 76.2%. Hot passes here measured 76.2 and 74.2, so the regime is
  # what is stable, not the decimal -- a one-point tolerance fails on a good run.
  run python3 -c "import sys; v=float('$acc'); sys.exit(0 if 70.0 <= v <= 80.0 else 1)"
  [ "$status" -eq 0 ]
}

@test "the cache-ram comparison is measured or absent, never assumed" {
  [ -f "$REC" ]
  [ -f "$WRITEUP" ]
  # Either the A/B pair exists in the record, or the writeup makes no cache-ram
  # claim. What is forbidden is asserting the explanation without the arm.
  local pair
  pair=$(awk -F'\t' '$1=="np1-mtp" || $1=="np1-cache8192"' "$REC" | wc -l)
  if [ "$pair" -lt 2 ]; then
    run grep -ci 'cache.ram\|cache_ram' "$WRITEUP"
    [ "$output" = "0" ]
  else
    # The pair must differ in cache_ram and nothing else that matters.
    run python3 - "$REC" <<'PY'
import sys, csv
rows={r['label']:r for r in csv.DictReader(open(sys.argv[1]), delimiter='\t')}
a,b=rows.get('np1-mtp'),rows.get('np1-cache8192')
same=all(a[k]==b[k] for k in ('slots','ctx_total','spec_type','workload','pool','reps'))
print('ok' if same and a['cache_ram']!=b['cache_ram'] else 'mismatched')
PY
    [ "$output" = "ok" ]
  fi
}
