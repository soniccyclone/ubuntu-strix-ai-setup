#!/usr/bin/env bats
# CUJ-08 — a stranger reading the repository's description of itself finds
# claims that are still true.

@test "every suite count the README states matches the suites present" {
  actual=$(ls tests/*.bats | wc -l)
  # The README states this in more than one place. A test reading "the number in
  # the README" would match the first and let the rest rot.
  mapfile -t claims < <(grep -oE '[0-9]+ (bats )?suites' README.md | grep -oE '^[0-9]+')
  [ "${#claims[@]}" -ge 2 ]
  for c in "${claims[@]}"; do
    [ "$c" -eq "$actual" ]
  done
}

@test "the agent-instruction files carry no unfilled template prompts" {
  # The placeholder form is _Add ..._ . Matching the narrower "_Add ...here_"
  # would have gone green with one stub still in the file.
  for f in CLAUDE.md AGENTS.md; do
    run grep -nE '_Add [^_]*_' "$f"
    [ "$status" -ne 0 ]
  done
}

@test "the agent-instruction files point at the documentation rather than restating it" {
  # Each section that replaced a stub must name an existing authority, and that
  # authority must exist. A pointer to a deleted file is worse than a stub.
  for f in CLAUDE.md AGENTS.md; do
    grep -q 'make help' "$f"
    grep -q 'README.md' "$f"
    grep -q 'docs/kairic-operations.md' "$f"
  done
  [ -f README.md ]
  [ -f docs/kairic-operations.md ]
  run make -s help
  [ "$status" -eq 0 ]
}

@test "CLAUDE.md and AGENTS.md do not disagree" {
  # These are independent files and legitimately differ: AGENTS.md carries a
  # bd-generated Codex block and Codex-specific shell guidance that CLAUDE.md
  # has no use for. Requiring them identical would be wrong.
  #
  # What must not drift is the project's own content, which lives in a marked
  # block in both. Compare exactly that.
  block() {
    sed -n '/BEGIN PROJECT NOTES/,/END PROJECT NOTES/p' "$1"
  }
  [ -n "$(block CLAUDE.md)" ]
  [ -n "$(block AGENTS.md)" ]
  diff <(block CLAUDE.md) <(block AGENTS.md)
}
