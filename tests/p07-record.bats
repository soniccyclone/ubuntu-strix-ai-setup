#!/usr/bin/env bats
# CUJ-07 — a reader who distrusts the numbers can check them.
#
# Draft acceptance ranges 46-76% on workload alone, so a row that does not name
# its workload is unreadable rather than merely incomplete.

REC=bench/parallel-scaling.tsv

rows() { tail -n +2 "$REC" | grep -c . ; }
col()  { head -1 "$REC" | tr '\t' '\n' | grep -nx "$1" | cut -d: -f1; }

@test "every row names slot count, spec type, context, cache-ram and workload" {
  [ -f "$REC" ]
  [ "$(rows)" -ge 13 ]
  for c in slots ctx_total ctx_per_slot cache_ram spec_type workload; do
    local i; i=$(col "$c")
    [ -n "$i" ]
    run awk -F'\t' -v i="$i" 'NR>1 && $i==""{c++} END{print c+0}' "$REC"
    [ "$output" = "0" ]
  done
}

@test "the record distinguishes this machine's figures from quoted ones" {
  [ -f "$REC" ]
  [ "$(rows)" -ge 13 ]
  # A dedicated column, not a free-text note. media-timings.tsv carries this in
  # prose and m08-timings.bats greps it; a column cannot drift into ambiguity.
  local i; i=$(col provenance)
  [ -n "$i" ]
  run awk -F'\t' -v i="$i" 'NR>1 && $i !~ /measured on this box|cited:/{c++} END{print c+0}' "$REC"
  [ "$output" = "0" ]
}

@test "the harness that produced the record is in the repository and runnable" {
  [ -x bench/parallel-sweep.sh ]
  [ -f tools/concbench.py ]
  run python3 -c "import ast,sys; ast.parse(open('tools/concbench.py').read())"
  [ "$status" -eq 0 ]
  run bash -n bench/parallel-sweep.sh
  [ "$status" -eq 0 ]
}

@test "the record's per-slot context is consistent with its own total and slots" {
  [ -f "$REC" ]
  [ "$(rows)" -ge 13 ]
  # Arithmetic the reader would do to check us. If it does not hold, one of the
  # three columns is lying about what the arm actually ran.
  local ct cps sl
  ct=$(col ctx_total); cps=$(col ctx_per_slot); sl=$(col slots)
  run awk -F'\t' -v t="$ct" -v p="$cps" -v s="$sl" \
      'NR>1 && $p+0 != int($t/$s){c++} END{print c+0}' "$REC"
  [ "$output" = "0" ]
}
