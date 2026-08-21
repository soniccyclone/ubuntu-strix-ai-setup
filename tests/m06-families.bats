#!/usr/bin/env bats
# CUJ-06 — any model family the box can hold, reachable the same way.

HOST=127.0.0.1:8188

setup_file() {
  curl -sf -m 10 "http://$HOST/system_stats" >/dev/null \
    || { echo "media-comfy not answering" >&2; return 1; }
}

@test "more than one model family runs against one service" {
  # Qwen-Image (20B, its own text encoder), FLUX.2 klein (4B + Qwen3-4B
  # encoder) and SDXL (2.6B, CLIP) share one container and one endpoint.
  run python3 tools/pixel_ab.py klein --only chest --out /tmp/fam-$$ 
  [ "$status" -eq 0 ]
  run python3 tools/pixel_ab.py sdxl --only chest --out /tmp/fam-$$
  [ "$status" -eq 0 ]
  rm -rf /tmp/fam-$$
}

@test "a missing weight file fails by name" {
  # The published workflows reference bf16 filenames while the fetch script
  # defaults to fp8, so this mismatch is the common case rather than an edge.
  # The fixture is a VALID graph whose only fault is the filename -- an invalid
  # graph trips type validation first and never reaches the weight lookup.
  run bash -c 'timeout 120 python3 tools/imgbench.py tests/fixtures/missing-weight.json --runs 1 2>&1'
  [ "$status" -ne 0 ]
  # Names the file, the node and the input, not a stack trace.
  [[ "$output" == *"definitely-not-here.safetensors"* ]]
  [[ "$output" == *"UNETLoader.unet_name"* ]]
  [[ "$output" != *"Traceback"* ]]
}

@test "the service reports which weights it can actually see" {
  # So a filename mismatch is diagnosable without reading a stack trace.
  run curl -sf -m 10 "http://$HOST/object_info/UNETLoader"
  [ "$status" -eq 0 ]
  jq -e '.UNETLoader.input.required.unet_name[0] | length > 0' <<<"$output" >/dev/null
  [[ "$output" == *"klein"* ]]
}
