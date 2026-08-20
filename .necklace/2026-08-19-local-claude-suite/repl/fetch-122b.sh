#!/usr/bin/env bash
# Fetch both 122B candidates for the deep-tier A/B.
#
# Parallel on purpose: Hugging Face rate-limits per connection, so five streams
# beat one on a gigabit line. Two traps this avoids, both hit today:
#   - files over ~50 GB are split by HF, so the single-file URL 404s
#   - a marker file is written only after curl exits clean, so a truncated
#     download never looks finished to the benchmark harness
set -u
LM=https://huggingface.co/lmstudio-community/Qwen3.5-122B-A10B-GGUF/resolve/main
BZ=https://huggingface.co/Beinsezii/Qwen3.5-122B-A10B-GGUF-HALO/resolve/main
A=$HOME/models/qwen3.5-122b
B=$HOME/models/qwen3.5-122b-halo
mkdir -p "$A" "$B"

get () {   # get <dir> <url> <outfile> <marker>
  for _ in $(seq 1 12); do
    if curl -sfL -C - -o "$1/$3" "$2"; then touch "$4"; return 0; fi
    sleep 5
  done
  echo "FAILED $3" >&2
}

get "$A" "$LM/Qwen3.5-122B-A10B-Q4_K_M-00001-of-00002.gguf" Qwen3.5-122B-A10B-Q4_K_M-00001-of-00002.gguf "$A/.p1" &
get "$A" "$LM/Qwen3.5-122B-A10B-Q4_K_M-00002-of-00002.gguf" Qwen3.5-122B-A10B-Q4_K_M-00002-of-00002.gguf "$A/.p2" &
get "$A" "$LM/mmproj-Qwen3.5-122B-A10B-BF16.gguf"           mmproj-BF16.gguf                             "$A/.mm" &
get "$B" "$BZ/qwen35-122b-a10b-q80-q6k_ffn.gguf"            qwen35-122b-a10b-q80-q6k_ffn.gguf            "$B/.w"  &
get "$B" "$BZ/mmproj-F16.gguf"                              mmproj-F16.gguf                              "$B/.mm" &
wait
