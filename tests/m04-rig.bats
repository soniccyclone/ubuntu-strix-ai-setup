#!/usr/bin/env bats
# CUJ-04 — a humanoid comes back rigged and moving.

RIG=http://127.0.0.1:8191
FIX=tests/fixtures
DRIVER="${T2M_RIG_DRIVER:-$HOME/.local/share/text-to-3d-toolkit/layers/rig/src/rig.py}"

setup_file() {
  curl -sf -m 10 "$RIG/health" >/dev/null || { echo "media-rig not answering" >&2; return 1; }
  [ -f "$DRIVER" ] || { echo "rig driver not at $DRIVER" >&2; return 1; }
  OUTDIR=/tmp/rig-test-$$; mkdir -p "$OUTDIR"; export OUTDIR
  T2M_RIG_DRIVER="$DRIVER" tools/rig.sh --glb "$FIX/warrior-12k.glb" --out-dir "$OUTDIR" >/dev/null
  export RIGGED="$OUTDIR/warrior-12k-rigged.glb"
  [ -f "$RIGGED" ] || RIGGED=$(ls "$OUTDIR"/*.glb | head -1)
  export RIGGED
}
teardown_file() { rm -rf /tmp/rig-test-*; }

@test "the rigged file carries skin data and named clips" {
  run python3 tools/glbinfo.py "$RIGGED"
  [ "$status" -eq 0 ]
  [ "$(jq -r .skins <<<"$output")" -ge 1 ]
  [ "$(jq -r .joints <<<"$output")" -ge 20 ]
  [ "$(jq -r .has_joints_attr <<<"$output")" = "true" ]
  jq -e '.animations | index("idle")' <<<"$output" >/dev/null
  jq -e '.animations | index("walk")' <<<"$output" >/dev/null
}

@test "joints use the conventional naming" {
  # The project skips retargeting by naming joints Mixamo's way. Wrong names is
  # where a walk cycle comes out backwards.
  run python3 tools/glbinfo.py "$RIGGED"
  [[ "$output" == *"mixamorig:"* ]]
}

@test "rigging preserves the materials the mesh arrived with" {
  # Skinning is appended to the GLB rather than rebuilt from it, which is the
  # project's stated reason for doing it that way.
  before=$(python3 tools/glbinfo.py "$FIX/warrior-12k.glb" | jq -r .textures)
  after=$(python3 tools/glbinfo.py "$RIGGED" | jq -r .textures)
  [ "$before" = "$after" ]
  tb=$(python3 tools/glbinfo.py "$FIX/warrior-12k.glb" | jq -r .triangles)
  ta=$(python3 tools/glbinfo.py "$RIGGED" | jq -r .triangles)
  [ "$tb" = "$ta" ]
}

@test "the rigged file still validates" {
  run node scripts/validate-glb.mjs "$RIGGED"
  [[ "$output" == *"0 errors"* ]]
}
