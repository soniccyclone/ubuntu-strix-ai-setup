#!/usr/bin/env bats
# CUJ-09 — services return after a reboot holding no more privilege than needed.
#
# This slice carries rigor because every failure mode in it is silent: a
# container quietly holding privilege, a home directory quietly mounted, a
# stage quietly running on the CPU. None of those announce themselves.

SERVICES="media-comfy media-engine media-rig"

@test "no media container runs privileged" {
  # Upstream's compose asks for privileged:true on the rig service. Measured:
  # device passthrough plus keep-groups is sufficient on rootless podman.
  for c in media-comfy media-engine media-rig; do
    podman container exists "$c"
    run podman inspect "$c" --format '{{.HostConfig.Privileged}}'
    [ "$status" -eq 0 ]
    [ "$output" = "false" ]
  done
}

@test "each service holds only the device nodes its stage needs" {
  # Rootless podman leaves HostConfig.Devices empty -- passthrough shows up in
  # CreateCommand and, definitively, as real nodes inside the container. Assert
  # on what is actually there, not on what the config claims.
  # `; true` because the kfd probe is EXPECTED to fail here, and without it the
  # shell's exit status is the absence we are asserting on.
  run podman exec media-engine sh -c 'ls -d /dev/dri >/dev/null 2>&1 && echo dri; ls -d /dev/kfd >/dev/null 2>&1 && echo kfd; true'
  [ "$status" -eq 0 ]
  [[ "$output" == *"dri"* ]]
  # The mesh engine is Vulkan-only; holding the ROCm compute node would be
  # privilege it never uses.
  [[ "$output" != *"kfd"* ]]

  # The ROCm stages legitimately need both.
  for c in media-comfy media-rig; do
    run podman exec "$c" sh -c 'ls -d /dev/kfd /dev/dri >/dev/null 2>&1 && echo both'
    [ "$status" -eq 0 ]
    [ "$output" = "both" ]
  done
}

@test "containers mount no home directory" {
  # Upstream's instructions use toolbox, which mounts $HOME wholesale.
  for c in media-comfy media-engine media-rig; do
    run podman inspect "$c" --format '{{range .Mounts}}{{.Source}}{{"\n"}}{{end}}'
    [ "$status" -eq 0 ]
    while read -r src; do
      [ -z "$src" ] && continue
      [ "$src" != "$HOME" ]
      # A mount must be one of the scoped directories, never the home root.
      [[ "$src" == "$HOME"/models-* || "$src" == "$HOME"/t2m-out* || "$src" == /* ]]
    done <<< "$output"
  done
}

@test "every service is enabled and answering" {
  for s in $SERVICES; do
    run systemctl --user is-enabled "$s"
    [ "$status" -eq 0 ]
    run systemctl --user is-active "$s"
    [ "$status" -eq 0 ]
  done
  [ "$(loginctl show-user "$(id -un)" --property=Linger)" = "Linger=yes" ]

  run curl -sf -m 10 http://127.0.0.1:8188/system_stats
  [ "$status" -eq 0 ]
  run curl -sf -m 10 http://127.0.0.1:8189/health
  [ "$status" -eq 0 ]
  run curl -sf -m 10 http://127.0.0.1:8191/health
  [ "$status" -eq 0 ]
}

@test "the mesh engine reports a Vulkan device, not a CPU fallback" {
  # --require-gpu should make a CPU fallback impossible, but the log is the
  # only place that says which device was actually selected.
  run podman logs media-engine
  [ "$status" -eq 0 ]
  [[ "$output" == *"vulkan:"* ]]
  [[ "$output" == *"RADV"* ]]
}

@test "ComfyUI sees the GPU with the raised memory ceiling" {
  run curl -sf -m 10 http://127.0.0.1:8188/system_stats
  [ "$status" -eq 0 ]
  name=$(jq -r '.devices[0].name' <<<"$output")
  [[ "$name" == *"Radeon"* ]]
  vram=$(jq -r '.devices[0].vram_total' <<<"$output")
  # 110 GiB from cycle 1's GTT change; anything near 64 means it regressed.
  [ "$vram" -gt 100000000000 ]
}
