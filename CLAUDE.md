# Project Instructions for AI Agents

This file provides instructions and context for AI coding agents working on this project.

<!-- BEGIN BEADS INTEGRATION v:1 profile:minimal hash:1105d646 -->
## Beads Issue Tracker

This project uses **bd (beads)** for issue tracking. Run `bd prime` to see full workflow context and commands.

### Quick Reference

```bash
bd ready              # Find available work
bd show <id>          # View issue details
bd update <id> --claim  # Claim work
bd close <id>         # Complete work
```

### Rules

- Use `bd` for ALL task tracking — do NOT use TodoWrite, TaskCreate, or markdown TODO lists
- Run `bd prime` for detailed command reference and session close protocol
- Use `bd remember` for persistent knowledge — do NOT use MEMORY.md files

**Architecture in one line:** issues live in a local Dolt DB; sync uses `refs/dolt/data` on your git remote; `.beads/issues.jsonl` is a passive export. See https://github.com/gastownhall/beads/blob/main/docs/core-concepts/sync-concepts.md for details and anti-patterns.

## Agent Context Profiles

The managed Beads block is task-tracking guidance, not permission to override repository, user, or orchestrator instructions.

- **Conservative (default)**: Use `bd` for task tracking. Do not run git commits, git pushes, or Dolt remote sync unless explicitly asked. At handoff, report changed files, validation, and suggested next commands.
- **Minimal**: Keep tool instruction files as pointers to `bd prime`; use the same conservative git policy unless active instructions say otherwise.
- **Team-maintainer**: Only when the repository explicitly opts in, agents may close beads, run quality gates, commit, and push as part of session close. A current "do not commit" or "do not push" instruction still wins.

## Session Completion

This protocol applies when ending a Beads implementation workflow. It is subordinate to explicit user, repository, and orchestrator instructions.

1. **File issues for remaining work** - Create beads for anything that needs follow-up
2. **Run quality gates** (if code changed) - Tests, linters, builds
3. **Update issue status** - Close finished work, update in-progress items
4. **Handle git/sync by active profile**:
   ```bash
   # Conservative/minimal/default: report status and proposed commands; wait for approval.
   git status

   # Team-maintainer opt-in only, unless current instructions forbid it:
   git pull --rebase
   git push
   git status
   ```
5. **Hand off** - Summarize changes, validation, issue status, and any blocked sync/commit/push step

**Critical rules:**
- Explicit user or orchestrator instructions override this Beads block.
- Do not commit or push without clear authority from the active profile or the current user request.
- If a required sync or push is blocked, stop and report the exact command and error.
<!-- END BEADS INTEGRATION -->


<!-- BEGIN PROJECT NOTES -->
## Build & Test

`make help` lists every target with its arguments. It is the interface; there is
no second set of commands hiding in a script.

```
make setup    # check bats, jq, podman, dolt
make test     # every bats suite
make env      # write .env if absent, regenerate the serving overlay
make status   # what is running and what it costs, including GPU memory
make stop-all # stop everything this repo can start, then prove it
```

## Architecture Overview

[README.md](README.md) covers the three subsystems and how they relate.
[docs/kairic-operations.md](docs/kairic-operations.md) is the operations manual:
tuning, memory behaviour, and troubleshooting by symptom.

Two things that are not obvious from the code and cause real mistakes:

- **Machine-local paths live in `.env`**, which is gitignored. The tracked
  configs in `config/` reference macros they do not define, so they cannot load
  alone — that is deliberate, and the error names the missing value. Run
  `make env` after editing `.env`.
- **Watch GTT, not RSS.** On this unified-memory APU the weights live in GTT.
  `ps`, `top` and `podman stats` will report a few GB while 91 GiB is in use.
  Read `/sys/class/drm/card*/device/mem_info_gtt_used`.

## Conventions & Patterns

- Tests are bats, one suite per CUJ, named for the property they assert rather
  than the function they call. Write the test first and watch it fail; a test
  that passes when written is testing nothing.
- Every measurement in this repository was taken on the machine described in
  [README.md](README.md), and the method is published beside the number.
- The development record is in `.necklace/`, including what was tried and
  abandoned. Read the relevant ledger before changing a design decision.
- Nothing here escalates privilege. Steps needing root are printed for a human
  to run: [docs/privileged-steps.md](docs/privileged-steps.md).
<!-- END PROJECT NOTES -->
