# What becomes public when this repository does

Making a repository public publishes every ref on the remote, not the file list
you see on the web page. This project syncs its issue tracker through that same
remote, so the issue database ships with the code. That is a decision worth
making deliberately rather than discovering afterwards.

`scripts/audit-refs.sh` checks the live remote against the table below and fails
on anything not listed. The table is the allowlist, so a ref cannot be waved
through without also being written down here.

| Ref | What it holds |
| --- | --- |
| `refs/heads/master` | The code, documentation, tests and the `.necklace/` development record. |
| `refs/dolt/data` | The beads issue database: every issue, its full edit history, and the events behind it. Audited 2026-08-26 with dolt v2.3.1 — no credentials, no deleted issues, and no secrets across 243 distinct historical text blobs. |
| `refs/heads/__dolt_remote_info__` | Bookkeeping written by beads' git-remote transport. Not a Dolt branch; `dolt branch -a` shows only `main` and `remotes/origin/main`. |

## What was checked before publishing

Working tree and every commit swept for key, credential and token shapes
(`hf_`, `sk-`, `ghp_`, `github_pat_`, `AKIA`, `xox[bp]-`, PEM headers): nothing.
The four files committed and later deleted — `.codex/config.toml`,
`.codex/hooks.json`, `.cursor/*`, `config/opencode-kairic.json` — were read from
their historical blobs and hold only beads scaffolding and a loopback baseURL.

Inside the issue database: seven of 32 tables hold anything. `config` carries
compaction settings and the issue prefix, not the `linear.api_key` or
`github.token` that beads warns can live there. Every issue ID appearing in
`events` also exists in `issues`, so no deleted issues are hiding in it.

The only personal identifiers anywhere are the commit email and author name,
which are already on every commit and cannot be removed without rewriting all
of them.

## The one thing that was removed

A beads issue analysed a defect in a named third-party project. It was never a
workaround this repository depends on, and publishing it would be a bug report
filed where its subject cannot answer. It was removed from the working tree and
from both histories rather than merely deleted, because a deletion in an
append-only store writes a new version and leaves the old ones.

See `.necklace/2026-08-26-public-release/` for the full audit.
