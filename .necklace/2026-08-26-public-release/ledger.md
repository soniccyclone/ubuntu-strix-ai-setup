# Ledger — public release preparation

Started 2026-08-26. Repo is private at `soniccyclone/ubuntu-strix-ai-setup`; the
question is what has to be true before it is not.

## Where this came from

An audit of the tree and its history ahead of flipping visibility. Findings, in
brief: no secrets in the working tree or in any historical blob (checked the
four files that were committed then deleted — all beads scaffolding); every
external source public; only personal identifiers are the commit email, already
public on every push, and the hostname ZOYSIA.

Six items came out of it. Five are work, one is a question for Nathan.

## The path problem is not one problem

Started by assuming `/home/nathan` could become `$HOME` and moved on. Wrong on
two counts, and the probes are what corrected it.

**llama-swap does not expand environment variables, and does not fail quietly
about it.** `repl/envexpand.sh` put `${NECKLACE_PROBE}` in a `cmd` with the
value exported. llama-swap v250 (60226b6):

    ERROR failed to load config error="unknown macro '${NECKLACE_PROBE}'
    found in probe.cmd"

`${...}` is llama-swap's own macro namespace, and anything undeclared is a
fatal config error rather than a passthrough. So `${HOME}/models` in
`llama-swap.yaml` is not a smaller fix than rendering the file; it is a config
that refuses to load.

**The systemd units were already fine.** Reading them instead of trusting the
grep: every runtime path already uses `%h`, and `scripts/setup-kairic.sh`
already rewrites the repo location with

    sed "s|%h/code-stuff/ubuntu-strix-ai-setup|$REPO|g"

The only literal `/home/nathan` in a unit is the `Documentation=` line, which is
metadata and runs nothing. The grep counted 11 hits and made two very different
problems look like one.

**What actually defeats portability** is that the setup script honours
`MODELS="${MODELS:-$HOME/models}"` and then hands llama-swap a YAML with
`/home/nathan/models` compiled into it. Setting `MODELS=/data/weights` today
produces a correct unit pointing at a config that ignores it. The parameter
exists and is inert.

## Macros merge across files, and cannot be overridden

`repl/macro-overlay.sh` and `repl/macro-override.sh`, three arrangements each:

| arrangement | result |
| --- | --- |
| macros in one file, models in another, both under `-config-dir` | loads |
| `-config` for macros + `-config-dir` for models | loads |
| tracked file defines `m`, overlay redefines it | **fatal** |

    error="conflict at \"macros.m\": 90-local.yaml sets a different value
    than a previous source"

Both orderings conflict, so this is not a precedence question. A macro is
defined in exactly one place or the config does not load.

That kills the shape I expected to use — ship a sensible default, let the
machine override it. It also picks the design for us: the tracked config must
not define the path macros *at all*. `repl/macro-value.sh` confirms the value
propagates rather than merely validating, by having the launched process write
its own argv:

    ARGV=/srv/overlay/models/weights.gguf-5800

Overlay macro and `${PORT}` both resolved in a real launch.

**Consequence worth stating plainly:** the tracked YAML becomes inert on its
own. `-config llama-swap-kairic.yaml` alone will refuse to load, because `${m}`
is undefined until the overlay is present. That is a real cost and it is the
right trade — the alternative is a file that loads on any machine and silently
serves nothing, which is the failure mode this project keeps writing tests
against.

`repl/macro-in-env.sh` closes the last gap in that design: `llama-swap.yaml`
puts `LD_LIBRARY_PATH` in a model's `env:` list rather than in `cmd`, and
macros expand there too — the launched process reported
`SEEN=/srv/overlay/opt/llama.cpp/lib`. So one overlay covers every hardcoded
path in both YAMLs, with no special case.

## Two of my six items were wrong, and the research is what caught it

**ROCmFPX is not a conflict.** I reported `ciru-ai/ROCmFPX` and
`charlie12345/ROCmFPX` as two URLs for one project with one presumably stale.
`harness/Containerfile.kairic:3` already answers it:

> Separate image from rocmfpx-hip on purpose: different fork (ciru-ai, not
> charlie12345), different branch, and it needs a patched Composable Kernel
> that the other build does not.

Both images exist locally (`localhost/kairic:v1.1`,
`localhost/rocmfpx-hip:0fc9568`) and both are load-bearing: the README's
headline compares them. Nothing to delete. The real gap is that this lives in a
Containerfile comment, so a stranger reading the README sees two throughput
numbers with no way to learn they came from two different people's forks.

**`docs/upstream-patches.md` does not contain the defect analysis.** Grepping it
for the skeleton defect returns nothing. Its four sections are patch notes —
what was changed locally, why, and the condition that retires each one. Section
4 does contradict a published claim (`Limbicnation/pixel-art-lora`'s model card
says RGBA; every sprite is PNG colour type 2), but that fact is load-bearing:
`tools/key_bg.py` exists because of it and `tests/m01-sprite.bats` pins it.
Removing it would leave the workaround unexplained.

The defect analysis is only in beads issue `p11`.

## The dolt audit

No dolt binary was present; installed v2.3.1 user-level under
`~/.local/opt/dolt` and queried `.beads/embeddeddolt/ubuntu_strix_ai_setup`
directly. Read-only, nothing running against the database at the time.

Branches: `main` and `remotes/origin/main`. Nothing else. The
`refs/heads/__dolt_remote_info__` that `git ls-remote` shows is the git-remote
transport's bookkeeping, not a dolt branch.

Seven of 32 tables hold anything. `config` (10 rows) is compaction settings and
the issue prefix — no `linear.api_key`, no `github.token`, which is what the
commented-out keys in `.beads/config.yaml` warn can live there. `metadata` is
four UUIDs. `local_metadata` is dependency-coordination hashes.

Every issue ID appearing in `events` also exists in `issues`: 29, 29, and 29 in
the jsonl. No deleted issues are hiding in the database.

Across all 243 distinct historical text blobs in `dolt_history_issues`: no
secret-shaped strings, no email addresses, no absolute home paths. The only
identity fields are `nathanjbarlow@gmail.com` and `Nathan Barlow`, both already
public on all 114 git commits.

**The finding that matters:** `p11` exists in ten versions of
`dolt_history_issues`, and the database carries 1,648 historical rows against 29
current ones across 175 dolt commits. Editing or deleting the issue writes a
*new* version; it does not remove the ten. The same text is in one git commit
(`7b0c5cc`) via `.beads/issues.jsonl`.

So "remove the defect analysis" is three different jobs depending on how far it
has to go, and only the first is cheap. That is a decision for Nathan, not a
detail — recorded as an open question in the spec.

## Licensing has a precedent in Nathan's own work

The repo carries generated third-party content: `.beads/hooks/*` and the marked
blocks in `AGENTS.md` / `CLAUDE.md` come from beads, which is MIT
("Beads Contributors"). `node_modules/gltf-validator` is Apache-2.0 and is
gitignored, so it is not distributed.

`.claude/skills/necklace*/` looked like an ownership question and is not:
`soniccyclone/necklace` is Nathan's own repo, sole author, already public,
already Apache-2.0, with the appendix filled in as `Copyright 2026 Nathan
Barlow`, no NOTICE file, and a three-line `## License` section in its README.

Same author, same license, so copying its pattern here is consistent rather
than a choice needing defence. Follow it exactly.

## Noticed while reading, not in scope unless Nathan says so

`config/llama-swap.yaml`'s header says it binds `0.0.0.0` and that "the LAN is
closed with a firewall rule instead; see docs/privileged-steps.md". The file's
own `common` macro passes `--host 127.0.0.1`, and `docs/privileged-steps.md`
section 3 exists specifically to say that design was abandoned and no firewall
is needed. The comment describes a superseded design and contradicts both the
code below it and the document it cites. It sits in a file item 2 already opens.

## Nathan's answers to the open questions

**Defect analysis: full scrub, rewrite both histories.** Chosen over the
cheaper options because the repository has never been cloned, so the rewrite is
free exactly once and this is that moment.

**Agent-instruction stubs: point at the real docs.** The README, `make help`
and `docs/kairic-operations.md` stay the single source of truth; the stubs
become pointers rather than a second copy that drifts.

**Repository description: keep it understated** — "Agentic AI on a Strix Halo
box", matching the README's own title.

## Scoping the scrub before committing to it

Feasibility checked rather than assumed, because "rewrite both histories" is
easy to say and can turn out to be a week.

`dolt filter-branch -q <SQL> [<commit>]` exists in v2.3.1 and replays history
applying a SQL statement, which is the right shape for deleting one issue from
all 175 commits.

On the git side, `git-filter-repo` is not installed; the built-in
`filter-branch` is present and adequate at this size.

The blast radius is smaller than the file counts suggested and needs stating
precisely, because I got it wrong once already. Eighteen commits *touch*
`.beads/issues.jsonl`, and only three of those change whether the text is
present — but a blob persists across commits that do not touch it, so the text
is actually carried by every commit from `7b0c5cc` (#78 of 117) to HEAD. Forty
commits, all hashes from #78 onward changing.

The redeeming detail: the text exists in exactly one path. Searching every
commit on every ref for the defect wording returns `.beads/issues.jsonl` and
nothing else — no ledger, no doc, no test fixture. A single-path rewrite.

**Risk to carry into the next document:** a force-push over 40 rewritten
commits and a rewritten dolt history are two separate rewrites of two stores
that reference each other through `refs/dolt/data`. They have to be sequenced
and verified together, not independently, and "beads still syncs afterwards" is
a thing to prove rather than assume.
