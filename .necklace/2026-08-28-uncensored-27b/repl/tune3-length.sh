#!/usr/bin/env bash
# Does generation LENGTH close the ROCmI4 gap?
#
# Cache, batching and speculation settings explained none of it. Our pool
# completes in ~162 tokens; cafonez's 44.39 is for "full HumanEval". Speculation
# amortises its setup across the tokens produced, so short completions are the
# regime where a 16-token draft window pays worst.
#
# 1024 rather than 2048: half the cost, and if the trend exists at all it will
# be visible between 512 and 1024. Both engines are measured at the same length
# or the comparison means nothing.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
export OUT="$HERE/rocmi4-length.tsv"
echo "reference at maxtok 512:  rocmi4 34.95   kairic 48.75"
MAXTOK=1024 "$HERE/rocmi4-vs-kairic.sh" 2>&1 | grep -E 'per-stream|GTT before|cleanup'
