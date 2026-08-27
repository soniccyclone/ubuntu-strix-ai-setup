#!/usr/bin/env bats
# CUJ-07 — a stranger auditing the security posture finds no tracked file
# contradicting itself.
#
# The contract's header claimed it bound 0.0.0.0 and needed a firewall rule.
# Its own macro passed --host 127.0.0.1 three lines below, and
# docs/privileged-steps.md section 3 exists to record that the firewall design
# was abandoned as unnecessary. A comment that outlives the design it describes
# is read as current, which is worse than no comment.

CONFIGS=(config/llama-swap.yaml config/llama-swap-kairic.yaml)

@test "a contract config's stated bind address matches the one it passes" {
  for cfg in "${CONFIGS[@]}"; do
    # What the file actually passes.
    passed=$(grep -oE -- '--host [0-9.]+' "$cfg" | awk '{print $2}' | sort -u)
    [ -n "$passed" ]
    [ "$(echo "$passed" | wc -l)" -eq 1 ]
    # Any address named in a comment must be that same one.
    claimed=$(grep -E '^\s*#' "$cfg" | grep -oE '\b(0\.0\.0\.0|127\.0\.0\.1)\b' | sort -u || true)
    for c in $claimed; do
      [ "$c" = "$passed" ]
    done
  done
}

@test "no tracked file claims a firewall is required" {
  # privileged-steps.md section 3 may describe the superseded plan, but only in
  # the past tense and only to say it is not needed. Nothing may assert it is.
  # Records are exempt: .necklace/ prose and the beads export both quote the
  # defect in order to describe it. Everything the project says about itself in
  # config, docs, units and scripts is in scope.
  run bash -c "git ls-files -z \
    | grep -zvE '^(\.necklace/|\.beads/issues\.jsonl$)' \
    | xargs -0 grep -inE 'closed with a firewall|firewall rule instead|requires? a firewall|need(s|ed)? a firewall' 2>/dev/null || true"
  [ -z "$output" ]
}

@test "the isolation tests still prove the binding directly" {
  # Asserting the listening address beats inferring it from a refused
  # connection, because a refusal could come from a firewall someone later
  # disables. Pin that so the weaker form cannot creep back.
  grep -q 'ss -ltn' tests/09-isolation.bats
  grep -qE '127\.0\.0\.1:\$\{CONTRACT_PORT\}' tests/09-isolation.bats
  # And it must reject the wildcard binds, not merely find the loopback one.
  grep -qE '0\.0\.0\.0:\$\{CONTRACT_PORT\}' tests/09-isolation.bats
}
