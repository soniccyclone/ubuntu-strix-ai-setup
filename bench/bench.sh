#!/usr/bin/env bash
# llama-bench harness. Two things it does that the bare command does not:
# refuses to run while anything is competing for the memory controller, and
# samples gpu_busy_percent alongside, because a low t/s with a saturated GPU
# and a low t/s with an idle GPU are opposite problems.
set -euo pipefail
LC=${LC:-$HOME/.local/opt/llama.cpp-vulkan/llama-b10502}
export LD_LIBRARY_PATH=$LC

# Match real curl processes by name, not by command-line substring. `pgrep -f`
# also matches this script's own wrapper and any shell that merely mentions a
# download, which produced both a phantom refusal and, elsewhere, a pkill that
# killed its caller.
if pgrep -x curl >/dev/null; then
  echo "refusing: curl is running and a download will skew the numbers" >&2
  pgrep -xa curl >&2
  exit 1
fi

if [ $# -lt 1 ]; then
  echo "usage: bench.sh <model.gguf> [llama-bench args...]" >&2
  exit 2
fi
model=$1; shift
if [ ! -f "$model" ]; then
  echo "no such model file: $model" >&2
  echo "models are not in this repository; see bench/results.md for which files were measured" >&2
  exit 2
fi
if [ ! -x "$LC/llama-bench" ]; then
  echo "llama-bench not found at $LC" >&2
  echo "set LC=/path/to/llama.cpp build, or fetch the prebuilt Vulkan release" >&2
  exit 2
fi
( for _ in $(seq 1 200); do
    cat /sys/class/drm/card1/device/gpu_busy_percent 2>/dev/null
    sleep 2
  done > /tmp/gpubusy.$$ ) & mon=$!
trap 'kill $mon 2>/dev/null' EXIT

"$LC/llama-bench" -m "$model" -ngl 999 -fa 1 -r 3 "$@" 2>&1 | grep -E '^\| |build:'

echo "--- gpu_busy_percent, 2s samples ---"
tr '\n' ' ' < /tmp/gpubusy.$$; echo
rm -f /tmp/gpubusy.$$
