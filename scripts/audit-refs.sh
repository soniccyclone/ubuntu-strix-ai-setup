#!/usr/bin/env bash
# Enumerate what the git remote actually carries, and fail on anything the
# publication record does not account for.
#
# Making a repository public publishes every ref, not the file list. Beads syncs
# its Dolt database through refs/dolt/data on the same remote, so the issue
# history ships with the code whether or not anyone meant it to. This is the
# check that turns that from a discovery into a decision.
#
#   scripts/audit-refs.sh                 query the configured remote
#   scripts/audit-refs.sh --refs-from -   read `git ls-remote` output on stdin
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DOC="$REPO/docs/publication-surface.md"
SRC="remote"
[ "${1:-}" = "--refs-from" ] && SRC="${2:?--refs-from needs a file or -}"

[ -f "$DOC" ] || { echo "[FAIL] no $DOC to audit against" >&2; exit 2; }

# The record's own table is the allowlist. One source of truth, so a ref added
# to the record without explanation is as visible as one added to the remote.
mapfile -t KNOWN < <(grep -oE '^\| `[^`]+`' "$DOC" | tr -d '|` ')

if [ "$SRC" = "remote" ]; then
  REFS=$(git -C "$REPO" ls-remote 2>/dev/null) || {
    echo "[FAIL] could not reach the remote" >&2; exit 2; }
else
  REFS=$(cat "$SRC")
fi

rc=0
while read -r _hash ref; do
  [ -n "${ref:-}" ] || continue
  [ "$ref" = "HEAD" ] && continue
  found=1
  for k in "${KNOWN[@]}"; do [ "$ref" = "$k" ] && { found=0; break; }; done
  if [ "$found" -ne 0 ]; then
    echo "[FAIL] ref not on the publication record: $ref" >&2
    rc=1
  fi
done <<< "$REFS"

[ "$rc" -eq 0 ] && echo "  [+] every ref on the remote is accounted for in $(basename "$DOC")"
exit "$rc"
