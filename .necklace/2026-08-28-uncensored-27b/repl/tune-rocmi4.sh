#!/usr/bin/env bash
# Attribute the ROCmI4-vs-Kairic gap rather than guess at it.
#
# The first comparison ran cafonez's published flags against Kairic's, and those
# differ in four ways at once. Kairic caches prompts and ROCmI4 did not, while
# the harness repeats the same eight tasks five times -- precisely the workload a
# prompt cache exploits. That alone could account for the gap, so it is tested
# first and separately.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
export OUT="$HERE/rocmi4-tuning.tsv"
run(){ printf '%-26s ' "$1"; shift; env "$@" ARMS_ONLY=rocmi4 "$HERE/rocmi4-vs-kairic.sh" 2>/dev/null \
        | grep -E 'per-stream' | head -1; }
echo "baseline for reference: kairic 48.75 tok/s, rocmi4-published-flags 34.95"
run "A +prompt cache"        I4_CACHE=16384
run "B +cache +big batch"    I4_CACHE=16384 I4_BATCH=2048 I4_UBATCH=512
run "C +cache +kairic spec"  I4_CACHE=16384 I4_NMAX=4 I4_PMIN=0.0
run "D all matched"          I4_CACHE=16384 I4_BATCH=2048 I4_UBATCH=512 I4_NMAX=4 I4_PMIN=0.0
