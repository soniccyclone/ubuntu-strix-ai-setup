#!/usr/bin/env bats
# CUJ-06 — the defect analysis is gone from the working tree and from both
# histories.
#
# A beads issue analysed a defect in a third party's project. Deleting it is not
# enough: the issue database is append-only, so a delete writes a new version and
# leaves the previous ones behind.
#
# The search needles are base64 here rather than in plain text. A test that
# proves a phrase is unpublished must not itself publish the phrase -- an earlier
# version stored them literally and became the only remaining hit in the whole
# repository. Encoding them means this file needs no exemption from its own
# scan, which is strictly better than excluding it.
MARKERS_B64=(dHdvIGxlZnQgbGVncw== c2tlbGV0b24ucHkgc2lkZXMgZWFjaCBsaW1i)

markers() {
  local b
  for b in "${MARKERS_B64[@]}"; do printf '%s\n' "$(echo "$b" | base64 -d)"; done
}

@test "the defect analysis is absent from the working tree" {
  while read -r m; do
    run bash -c "git ls-files -z | xargs -0 grep -lF -- \"\$1\" 2>/dev/null || true" _ "$m"
    [ -z "$output" ]
  done < <(markers)
}

@test "the defect analysis is absent from every commit on every ref" {
  # Every commit reachable from every ref, not merely those that touched the
  # file: a blob persists across commits that never modified it.
  local found=""
  while read -r m; do
    for c in $(git rev-list --all); do
      if git grep -l -F -e "$m" "$c" -- >/dev/null 2>&1; then
        found="$m in $c"
        break
      fi
    done
    [ -z "$found" ] || break
  done < <(markers)
  [ -z "$found" ]
}

@test "the defect analysis is absent from every version in the issue database" {
  command -v dolt >/dev/null || skip "dolt not installed"
  DB=.beads/embeddeddolt/ubuntu_strix_ai_setup
  [ -d "$DB" ]
  while read -r m; do
    run bash -c "cd '$DB' && dolt sql -r csv -q \"
      select count(*) from dolt_history_issues
      where coalesce(description,'')   like '%\$1%'
         or coalesce(close_reason,'')  like '%\$1%'
         or coalesce(notes,'')         like '%\$1%'
         or coalesce(design,'')        like '%\$1%'
         or coalesce(title,'')         like '%\$1%'\" | tail -1" _ "$m"
    [ "$status" -eq 0 ]
    [ "$output" = "0" ]
  done < <(markers)
}

@test "beads still syncs after the rewrite" {
  run bd list --status=closed --json
  [ "$status" -eq 0 ]

  # The database must still export, and the export must agree with the copy on
  # disk. A database that is intact but disagrees with its own export is the
  # failure mode a rewrite of two coupled stores actually produces.
  tmp="$BATS_TEST_TMPDIR/export.jsonl"
  run bd export -o "$tmp"
  [ "$status" -eq 0 ]
  [ "$(grep -c '"_type":"issue"' "$tmp")" -ge 1 ]
  diff <(sort "$tmp") <(sort .beads/issues.jsonl)

  run bd show ubuntu-strix-ai-setup-p11
  [ "$status" -ne 0 ]
}
