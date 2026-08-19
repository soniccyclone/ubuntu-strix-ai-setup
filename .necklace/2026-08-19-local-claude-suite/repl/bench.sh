#!/usr/bin/env bash
# llama-bench harness. Two things it does that the bare command does not:
# refuses to run while anything is competing for the memory controller, and
# samples gpu_busy_percent alongside, because a low t/s with a saturated GPU
# and a low t/s with an idle GPU are opposite problems.
set -euo pipefail
LC=${LC:-$HOME/.local/opt/llama.cpp-vulkan/llama-b10502}
export LD_LIBRARY_PATH=$LC

if pgrep -f "curl.*\.gguf" >/dev/null; then
  echo "refusing: a model download is running and will skew the numbers" >&2
  exit 1
fi

model=$1; shift
( for _ in $(seq 1 200); do
    cat /sys/class/drm/card1/device/gpu_busy_percent 2>/dev/null
    sleep 2
  done > /tmp/gpubusy.$$ ) & mon=$!
trap 'kill $mon 2>/dev/null' EXIT

"$LC/llama-bench" -m "$model" -ngl 999 -fa 1 -r 3 "$@" 2>&1 | grep -E '^\| |build:'

echo "--- gpu_busy_percent, 2s samples ---"
tr '\n' ' ' < /tmp/gpubusy.$$; echo
rm -f /tmp/gpubusy.$$
