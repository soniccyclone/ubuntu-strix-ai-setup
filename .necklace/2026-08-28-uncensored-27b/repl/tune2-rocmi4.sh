#!/usr/bin/env bash
# Cache and batching explained none of the gap. Two hypotheses left:
#
#  1. Generation LENGTH. Speculation amortises its setup over the tokens it
#     produces, and our pool completes in ~162 tokens. The card reports "full
#     HumanEval", which may mean longer generations where a 16-token draft
#     window finally pays. Kairic is measured at the same length so the
#     comparison stays honest.
#  2. A WIDER draft window. 16 beat 4 decisively, so the curve may not have
#     turned over yet.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
export OUT="$HERE/rocmi4-tuning2.tsv"
run(){ printf '%-30s ' "$1"; shift; env "$@" "$HERE/rocmi4-vs-kairic.sh" 2>/dev/null \
       | grep -E 'per-stream' | sed 's/^ *//' | paste -sd' | ' -; }
echo "reference at 512 tok: rocmi4 34.95, kairic 48.75"
run "long gen 2048, both engines"  MAXTOK=2048
run "draft window 32"              I4_NMAX=32 ARMS_ONLY=rocmi4
run "draft window 32, long gen"    I4_NMAX=32 MAXTOK=2048 ARMS_ONLY=rocmi4
