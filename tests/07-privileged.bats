#!/usr/bin/env bats
# CUJ-07 — a future maintainer sees exactly which steps needed root.

DOC=docs/privileged-steps.md

@test "every privileged step has a recorded rollback" {
  # Each numbered step must carry both a reason and an undo. The GTT commands
  # existed only in chat until Nathan asked for them before a reboot; that is
  # exactly where a rollback gets lost.
  steps=$(grep -cE '^## [0-9]+\.' "$DOC")
  [ "$steps" -ge 2 ]
  whys=$(grep -cE '^\*\*(Why|Superseded)\.\*\*' "$DOC")
  [ "$whys" -ge "$steps" ]
  # Every step names an undo path.
  undos=$(grep -ciE '^\*\*Rollback\.\*\*|already run.*undo|^\*\*Superseded' "$DOC")
  [ "$undos" -ge "$steps" ]
}

@test "no root command was executed by an agent" {
  # sudo -n fails in agent sessions here, so this is enforced rather than
  # promised. The document must say so where a reader will see it.
  grep -qiE 'handed to Nathan and run by him' "$DOC"
  grep -qiE 'sudo -n. fails|cannot escalate' "$DOC"
}

@test "the boot-argument change is reversible from its backup" {
  [ -f /etc/default/grub.bak ]
  # Exactly one line differs, and it is the kernel command line.
  run bash -c "diff /etc/default/grub.bak /etc/default/grub | grep -c '^[<>]'"
  [ "$status" -eq 0 ]
  [ "${output//[[:space:]]/}" = "2" ]
  run bash -c "diff /etc/default/grub.bak /etc/default/grub | grep '^>'"
  [[ "$output" == *"GRUB_CMDLINE_LINUX_DEFAULT"* ]]
}

@test "the user-level install is separable from anything root owns" {
  # Everything this project installed lives under $HOME and is removable
  # without root.
  for p in "$HOME/.local/opt/llama.cpp-vulkan" "$HOME/.local/opt/llama-swap" "$HOME/models"; do
    [ -e "$p" ]
    run find "$p" -maxdepth 3 ! -user "$(id -un)" -print -quit
    [ "$status" -eq 0 ]
    [ -z "$output" ]
  done
}
