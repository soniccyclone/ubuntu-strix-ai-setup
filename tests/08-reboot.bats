#!/usr/bin/env bats
# CUJ-08 — the stack returns after a reboot without being nursed.
#
# These assert the MECHANISM, not an actual reboot: units enabled, linger on,
# ceiling in the boot arguments and in effect. A genuine reboot is Nathan's to
# perform and its outcome is his UAT ("is it there when I open the laptop").
# A test that claims to prove reboot behaviour without rebooting would be lying.

CONTRACT="${CONTRACT:-http://127.0.0.1:8080}"

@test "the configured memory ceiling is in effect" {
  gtt=$(cat /sys/class/drm/card1/device/mem_info_gtt_total)
  [ "$gtt" -eq 118111600640 ]                     # 110.00 GiB
  vram=$(cat /sys/class/drm/card1/device/mem_info_vram_total)
  [ "$vram" -eq 536870912 ]                        # carve-out untouched at 512 MiB
  pages=$(cat /sys/module/ttm/parameters/pages_limit)
  [ "$pages" -eq 28835840 ]
}

@test "the ceiling is set in the boot arguments, so it survives a reboot" {
  grep -q "amdgpu.gttsize=112640" /proc/cmdline
  grep -q "ttm.pages_limit=28835840" /proc/cmdline
  # And it is persisted, not just live in this boot.
  grep -q "amdgpu.gttsize=112640" /etc/default/grub
}

@test "the contract starts without anyone starting it" {
  # Enabled units plus linger means these come up at boot with no login.
  run systemctl --user is-enabled llama-swap contract-socket
  [ "$status" -eq 0 ]
  run systemctl --user is-active llama-swap contract-socket
  [ "$status" -eq 0 ]
  [ "$(loginctl show-user "$(id -un)" --property=Linger)" = "Linger=yes" ]
}

@test "the running contract answers and is loopback-bound" {
  run curl -sf -m 10 "$CONTRACT/v1/models"
  [ "$status" -eq 0 ]
  jq -e '.data|length >= 3' <<<"$output" >/dev/null
  run ss -ltn "sport = :8080"
  [[ "$output" == *"127.0.0.1:8080"* ]]
  [[ "$output" != *"0.0.0.0:8080"* ]]
}

@test "the container path to the contract is up" {
  [ -S "${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/contract.sock" ]
  perms=$(stat -c '%a' "${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/contract.sock")
  [ "$perms" = "600" ]
}
