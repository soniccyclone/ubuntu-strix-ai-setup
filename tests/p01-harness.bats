#!/usr/bin/env bats
# CUJ-01 — per-stream and aggregate reported separately, with spread.
#
# They move in opposite directions: on the 4B, per-stream fell 28.87 -> 12.32
# while aggregate rose 27.67 -> 93.45. A single "throughput" figure that does
# not say which one it is cannot be read.

REC=bench/parallel-scaling.tsv
HARNESS=tools/concbench.py

col() { head -1 "$REC" | tr '\t' '\n' | grep -nx "$1" | cut -d: -f1; }

@test "every row carries both per-stream and aggregate throughput" {
  [ -f "$REC" ]
  # A record with no rows satisfies "no row is missing a column" for free.
  # Guard the vacuous pass: the sweep plan has thirteen arms.
  run bash -c "tail -n +2 '$REC' | grep -c . "
  [ "$output" -ge 13 ]
  local ps agg
  ps=$(col per_stream_tps); agg=$(col aggregate_tps)
  [ -n "$ps" ] && [ -n "$agg" ]
  # Neither may be blank or zero on any row.
  run awk -F'\t' -v p="$ps" -v a="$agg" \
      'NR>1 && ($p=="" || $a=="" || $p+0==0 || $a+0==0){c++} END{print c+0}' "$REC"
  [ "$output" = "0" ]
}

@test "every row carries the spread across its repeats" {
  [ -f "$REC" ]
  # A record with no rows satisfies "no row is missing a column" for free.
  # Guard the vacuous pass: the sweep plan has thirteen arms.
  run bash -c "tail -n +2 '$REC' | grep -c . "
  [ "$output" -ge 13 ]
  local reps psp asp
  reps=$(col reps); psp=$(col per_stream_spread_pct); asp=$(col aggregate_spread_pct)
  [ -n "$reps" ] && [ -n "$psp" ] && [ -n "$asp" ]
  # The noise floor here is 13% peak-to-peak, so fewer than five repeats is not
  # a measurement and a missing spread hides that.
  run awk -F'\t' -v r="$reps" -v p="$psp" -v a="$asp" \
      'NR>1 && ($r+0 < 5 || $p=="" || $a==""){c++} END{print c+0}' "$REC"
  [ "$output" = "0" ]
}

@test "aggregate is computed from batch wall time, not by summing request rates" {
  # Summing per-request rates double-counts overlapped time and reports a
  # speedup that did not occur. Assert the harness divides tokens by the wall
  # clock of the whole batch.
  grep -q 'tok / wall' "$HARNESS"
  run bash -c "grep -cE 'sum\(.*tps|sum\(r\[.per_stream' '$HARNESS'"
  [ "$output" = "0" ]
}

@test "the harness refuses to call fewer than five repeats a measurement" {
  run python3 "$HARNESS" --port 1 --streams 1 --reps 2 --workload prose
  # It may fail to connect -- that is fine, port 1 is closed. What must appear
  # is the warning about the repeat floor, before any connection is attempted.
  [[ "$output" == *"below the floor of 5"* ]]
}
