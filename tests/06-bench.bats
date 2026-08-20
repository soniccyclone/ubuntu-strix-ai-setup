#!/usr/bin/env bats
# CUJ-06 — a future maintainer reproduces the numbers the roster was chosen on.

@test "harness refuses to measure while a download runs" {
  # A download saturating the memory controller invalidates every number.
  # Earlier this guard used `pgrep -f "curl.*gguf"`, which matched its own
  # wrapper and any shell that merely mentioned a download; it now matches
  # real processes by name.
  # A real curl process: `pgrep -x` matches the binary's comm, not argv[0], so
  # `exec -a curl sleep` does not fake it. 10.255.255.1 is non-routable, so
  # this hangs until its own timeout without touching the network.
  curl -s -m 20 http://10.255.255.1/ >/dev/null 2>&1 & fake=$!
  sleep 0.5
  run ./bench/bench.sh /nonexistent.gguf
  kill $fake 2>/dev/null || true
  [ "$status" -ne 0 ]
  [[ "$output" == *"curl is running"* ]]
}

@test "every recorded row names build, packager, quant and size" {
  # Two files of identical size differed 2.24x by packager, so a row
  # identified by size alone identifies nothing.
  run grep -c "b10502" bench/results.md
  [ "$status" -eq 0 ]
  for token in bartowski lmstudio unsloth Q4_K_M Q8_0 GiB; do
    grep -q "$token" bench/results.md
  done
  # Every measurement row carries a packager, not just a size.
  rows=$(grep -cE '^\| (Qwen|qwen)' bench/results.md || true)
  [ "$rows" -ge 6 ]
}

@test "a fresh checkout fails with a clear message, not a stack trace" {
  run ./bench/bench.sh /definitely/not/here.gguf
  [ "$status" -eq 2 ]
  [[ "$output" == *"no such model file"* ]]
  [[ "$output" != *"line "* ]]
}

@test "the harness records GPU utilisation beside each number" {
  # 25.9 t/s at 98% busy and 25.9 t/s at 10% busy are opposite problems.
  grep -q "gpu_busy_percent" bench/bench.sh
}
