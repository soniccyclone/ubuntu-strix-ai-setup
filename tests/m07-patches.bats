#!/usr/bin/env bats
# CUJ-07 — a future maintainer sees which upstream projects were patched, and why.

DOC=docs/upstream-patches.md

@test "every patch records what it works around and when it expires" {
  [ -f "$DOC" ]
  n=$(grep -cE '^## [0-9]+\.' "$DOC")
  [ "$n" -ge 4 ]
  # Each entry must carry both halves. Recording only the reason turns a
  # temporary workaround into permanent folklore.
  [ "$(grep -c '^\*\*Why:\*\*' "$DOC")" -ge 3 ]
  [ "$(grep -c '^\*\*Expires when:\*\*' "$DOC")" -eq "$n" ]
}

@test "the dropped dependency is still unreachable" {
  # open3d was omitted because it has no cp313 wheel. That is only safe while
  # the modules importing it stay off the path.
  run podman run --rm --entrypoint /opt/venv/bin/python localhost/text-to-3d/rig:rocm \
      -c 'import importlib.util as u; print("present" if u.find_spec("open3d") else "absent")'
  [ "$status" -eq 0 ]
  [ "$output" = "absent" ]
  # And the service still works without it.
  run curl -sf -m 10 http://127.0.0.1:8191/health
  [ "$status" -eq 0 ]
}

@test "no service has regained privilege" {
  for c in media-comfy media-engine media-rig; do
    run podman inspect "$c" --format '{{.HostConfig.Privileged}}'
    [ "$output" = "false" ]
  done
}
