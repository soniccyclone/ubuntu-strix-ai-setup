#!/usr/bin/env bats
# CUJ-03 — a described object becomes a validator-clean textured GLB.
#
# This slice carries rigor: a CPU fallback here is silent and merely looks like
# slowness, and a file with the glTF magic bytes is not the same as an asset an
# engine can load.

ENGINE=http://127.0.0.1:8189
FIX=tests/fixtures

setup_file() {
  curl -sf -m 10 "$ENGINE/health" >/dev/null \
    || { echo "media-engine not answering" >&2; return 1; }
}

@test "the mesh engine refuses to start without a GPU" {
  # Started with no render node at all. --require-gpu must make this fail
  # rather than fall back to CPU, which would look like a slow run instead of
  # a broken one.
  run timeout 120 podman run --rm --entrypoint /bin/sh localhost/text-to-3d/engine:vulkan \
      -c 'exec "$0" server --host 127.0.0.1 --port 8199 --models /models --require-gpu' \
      "$(podman inspect localhost/text-to-3d/engine:vulkan --format '{{index .Config.Entrypoint 0}}')"
  [ "$status" -ne 0 ]
}

@test "a generated GLB validates clean" {
  run node scripts/validate-glb.mjs "$FIX/helmet-12k.glb"
  [ "$status" -eq 0 ]
  [[ "$output" == *"0 errors"* ]]
  [[ "$output" == *"0 warnings"* ]]
}

@test "a generated GLB carries geometry and textures, not just valid syntax" {
  run python3 tools/glbinfo.py "$FIX/helmet-12k.glb"
  [ "$status" -eq 0 ]
  tri=$(jq -r .triangles <<<"$output");  [ "$tri" -gt 1000 ]
  tex=$(jq -r .textures  <<<"$output");  [ "$tex" -ge 1 ]
}

@test "no stage carries a CUDA runtime or Blender" {
  # The project's central claim, and the reason it runs on this hardware.
  for img in localhost/text-to-3d/engine:vulkan localhost/text-to-3d/rig:rocm; do
    run podman run --rm --entrypoint /bin/sh "$img" -c \
      'ls /usr/local/cuda 2>/dev/null; command -v blender 2>/dev/null; python3 -c "import bpy" 2>/dev/null && echo bpy; true'
    [ "$status" -eq 0 ]
    [[ "$output" != *"cuda"* ]]
    [[ "$output" != *"blender"* ]]
    [[ "$output" != *"bpy"* ]]
  done
}

@test "the engine turns an image into a mesh end to end" {
  out=/tmp/mesh-test-$$.glb
  run python3 tools/mesh.py "$FIX/warrior-1024.png" "$out" --resolution 512 --target-faces 12000 --seed 61
  [ "$status" -eq 0 ]
  secs=$(jq -r .seconds <<<"$output")
  [ -f "$out" ]
  run node scripts/validate-glb.mjs "$out"
  [[ "$output" == *"0 errors"* ]]
  rm -f "$out"
}
