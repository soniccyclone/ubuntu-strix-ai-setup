#!/usr/bin/env bats
# CUJ-05 — Nathan sees what every published ref carries before the repository
# is public.
#
# Flipping visibility publishes more than the file list. `git ls-remote` shows
# refs/dolt/data and refs/heads/__dolt_remote_info__ beside the branch, both
# created by beads' git-remote transport.

DOC=docs/publication-surface.md

@test "the publication surface is recorded" {
  [ -f "$DOC" ]
  # Every ref the remote carries must appear, or the record is not a record.
  for ref in 'refs/heads/master' 'refs/dolt/data' 'refs/heads/__dolt_remote_info__'; do
    grep -qF "$ref" "$DOC"
  done
  # And each entry must say what it holds, not merely that it exists.
  [ "$(grep -cE '^\| `refs/' "$DOC")" -ge 3 ]
}

@test "the audit flags a ref that is not on the record" {
  run scripts/audit-refs.sh --refs-from /dev/null
  [ "$status" -eq 0 ]
  # An unrecorded ref must fail loudly and name itself, rather than being
  # counted and ignored.
  run bash -c "printf 'deadbeef\trefs/heads/surprise\n' | scripts/audit-refs.sh --refs-from -"
  [ "$status" -ne 0 ]
  [[ "$output" == *"refs/heads/surprise"* ]]
}

@test "the issue database carries no credentials" {
  command -v dolt >/dev/null || skip "dolt not installed"
  DB=.beads/embeddeddolt/ubuntu_strix_ai_setup
  [ -d "$DB" ]
  # beads warns that linear.api_key and github.token can live in these tables.
  run bash -c "cd '$DB' && dolt sql -q \"select \\\`key\\\`, value from config union all select \\\`key\\\`, value from metadata\" -r csv"
  [ "$status" -eq 0 ]
  run bash -c "echo '$output' | grep -inE 'api[_-]?key|token|secret|password|passwd' || true"
  [ -z "$output" ]
}
