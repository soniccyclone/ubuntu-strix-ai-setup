#!/usr/bin/env bats
# CUJ-02 — whether MTP still pays at four and eight slots.
#
# mathieu900v's actual claim. Speculation pays at one stream because compute is
# idle; concurrency supplies that arithmetic intensity itself, at which point
# drafting competes with real work.

REC="${REC:-bench/parallel-scaling.tsv}"
WRITEUP="${WRITEUP:-docs/parallel-scaling.md}"
# How many arms the sweep actually plans. Hardcoding this drifted once
# already: the guard said 13 after an arm was dropped to 12.
expected_arms() { grep -cE '^\s+"np[0-9]' bench/parallel-sweep.sh; }

rows() { tail -n +2 "$REC" | grep -c . ; }
col()  { head -1 "$REC" | tr '\t' '\n' | grep -nx "$1" | cut -d: -f1; }

@test "each MTP arm has a matched no-MTP arm differing only in spec type" {
  [ -f "$REC" ]
  [ "$(rows)" -ge "$(expected_arms)" ]
  # An earlier cycle's bench gave one arm draft flags the other lacked, which is
  # how a comparison quietly stops being one. Every condition except spec_type
  # must match between the pair.
  run python3 - "$REC" <<'PY'
import sys, csv, collections
rows=list(csv.DictReader(open(sys.argv[1]), delimiter='\t'))
key=lambda r:(r['group'],r['slots'],r['ctx_total'],r['cache_ram'],r['workload'],r['pool'],r['reps'])
byk=collections.defaultdict(set)
for r in rows: byk[key(r)].add(r['spec_type'])
# Every arm in the main and prose groups must have both spec types present.
bad=[k for k,v in byk.items() if k[0] in ('main','prose') and v!={'draft-mtp','none'}]
print(len(bad))
PY
  [ "$output" = "0" ]
}

@test "each arm records the speculative stack it actually loaded" {
  [ -f "$REC" ]
  [ "$(rows)" -ge "$(expected_arms)" ]
  # "--spec-type none" does NOT mean no speculation: the kairic-edge path loads
  # ngram-mod regardless, which drafts on code and not on prose. So the arms are
  # MTP-plus-default against default-alone, and each must say which
  # implementations it loaded rather than being trusted from its label.
  local st si dn da
  st=$(col spec_type); si=$(col spec_impls); dn=$(col draft_n); da=$(col draft_accept_pct)
  [ -n "$si" ]
  run awk -F'\t' -v i="$si" 'NR>1 && ($i=="" || $i=="none-loaded"){c++} END{print c+0}' "$REC"
  [ "$output" = "0" ]
  # The MTP arms must actually have loaded MTP, and the comparison arms must not.
  run awk -F'\t' -v s="$st" -v i="$si" \
      'NR>1 && $s=="draft-mtp" && $i !~ /mtp/{c++} END{print c+0}' "$REC"
  [ "$output" = "0" ]
  run awk -F'\t' -v s="$st" -v i="$si" \
      'NR>1 && $s=="none" && $i ~ /mtp/{c++} END{print c+0}' "$REC"
  [ "$output" = "0" ]
  # And a drafting arm must report acceptance, or the number says nothing.
  run awk -F'\t' -v n="$dn" -v a="$da" \
      'NR>1 && $n+0>0 && $a==""{c++} END{print c+0}' "$REC"
  [ "$output" = "0" ]
}

@test "a difference smaller than the combined spread is called inconclusive" {
  # The noise floor measured 13% peak-to-peak. Whatever the writeup concludes
  # about MTP, it must not name a winner for a gap the spread cannot resolve.
  [ -f "$WRITEUP" ]
  run python3 - "$REC" "$WRITEUP" <<'PY'
import sys, csv, collections, re
rows=list(csv.DictReader(open(sys.argv[1]), delimiter='\t'))
doc=open(sys.argv[2]).read().lower()
byk=collections.defaultdict(dict)
for r in rows:
    byk[(r['group'],r['slots'],r['workload'])][r['spec_type']]=r
unresolved=[]
for k,v in byk.items():
    if set(v)!={'draft-mtp','none'}: continue
    a,b=v['draft-mtp'],v['none']
    fa,fb=float(a['aggregate_tps']),float(b['aggregate_tps'])
    band=(float(a['aggregate_spread_pct'])+float(b['aggregate_spread_pct']))/2
    gap=100*abs(fa-fb)/((fa+fb)/2)
    if gap<band: unresolved.append(k)
# For every comparison the data cannot resolve, the writeup must say so.
missing=[k for k in unresolved if 'inconclusive' not in doc]
print(len(missing))
PY
  [ "$output" = "0" ]
}
