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

## Nathan asked why not a gitignored .env, and he is right

My design had setup generate the macro overlay from environment variables it
already honours. Nathan asked why the machine values do not simply live in a
gitignored `.env`. Three probes later, that is the better design, and the flaw
it fixes is one I had not noticed.

**What I missed.** `MODELS=/data make kairic-setup` works exactly once. Re-run
setup without repeating the variable and the overlay is regenerated from
`$HOME/models`. My design gave the values nowhere to live, so the machine's
configuration depended on a stranger remembering an environment variable
forever. A file is the obvious fix and I had walked past it.

**Where his idea needs one correction.** `.env` cannot feed llama-swap
directly — `envexpand.sh` already proved `KEY=value` is not a namespace it
reads. So `.env` is the *human* surface and the macro overlay is derived from
it. Two files, one of which nobody edits by hand.

**And a real bug in the naive shape.** `repl/env-shared.sh` tests the obvious
version: `-include .env` in the Makefile, `. ./.env` in the script. Make gets
the precedence right — command line beats the file. The shell does not:

    $ MODELS=/srv/from-command-line ./setup.sh
    sh sees MODELS=/srv/from-env-file

Sourcing assigns unconditionally, so the file clobbers what the caller
exported and precedence runs backwards. Two mechanisms fighting, with the
quieter one winning.

Rather than paper over that with a capture-and-restore dance, `.env` becomes
the sole source and the environment-variable path goes away. One place to look,
no precedence to reason about. `repl/env-to-overlay.sh` runs the whole chain:

    tracked config alone   -> error="model probe env: unknown macro '${opt}'"
    .env first run         -> created with detected defaults
    .env second run        -> exists, left untouched
    derived overlay        -> macros: {m: /srv/user-edited-this, ...}
    launched process       -> ARGV=/srv/user-edited-this/weights.gguf-5800

The first line is the one worth keeping. A tracked config that cannot work
alone says so by name, immediately, rather than loading and serving the wrong
weights.

## Folding in the stale contract comment

`config/llama-swap.yaml`'s header claims the file binds `0.0.0.0` and that "the
LAN is closed with a firewall rule instead". The macro three lines below passes
`--host 127.0.0.1`, and `docs/privileged-steps.md` section 3 exists to record
that the firewall design was abandoned and is not needed. The comment
contradicts both the code under it and the document it cites.

Nathan asked for it in scope. It is a public-facing falsehood about the
security posture of the thing, in a file this cycle already rewrites, and it
would be read by exactly the people most likely to check.

## Two assertions that would have passed while the thing rotted

Checking the CUJ's own claims before committing them caught two tests that
would have been written wrong.

The README states the suite count **twice** — `tests/  17 bats suites` at line
105 and `make test  # 17 suites` at line 119. A test reading "the number in the
README" would have matched the first and left the second to drift. The
assertion has to be that *every* stated count agrees.

And the placeholder form is not what I wrote. `grep -c '_Add .*here_'` returns
2, not 3: `_Add a brief overview of your project architecture_` does not end in
`here_`. A test matching the narrower form would have gone green with one stub
still sitting in the file. The assertion matches `_Add ..._`.

Both are the same failure: an assertion narrower than the thing it claims to
cover, which is the kind that passes forever and proves nothing.

## The unit test passed and the thing was broken

CUJ-01's tests went green against a synthetic probe config. Running the *real*
tracked configs through the same overlay found `llama-swap.yaml` refusing to
load:

    error="unknown macro '${opt}' found in fast.cmd"

`repl/macro-compose-order.sh` isolates it. A macro may reference another macro,
but only if both definitions are visible when the referring file is parsed:

| arrangement | result |
| --- | --- |
| composed, both files in one `-config-dir` | loads |
| composed, `-config` tracked + `-config-dir` overlay | **fails** |
| inlined, `-config` tracked + `-config-dir` overlay | loads |
| composed, `-config` overlay + `-config-dir` tracked | loads |

`-config` is resolved before `-config-dir` is merged, so a `server:` macro in
the tracked file referencing the overlay's `${opt}` is expanded while `${opt}`
is still undefined.

The earlier `macro-in-macro.sh` probe put both files in one `-config-dir` and
reported composition as safe. It was measuring the one arrangement the unit
does not use. That is the whole failure: a probe that answered a slightly
different question than the one the design depended on.

Fixed by writing the llama-server path out at each use site instead of hoisting
it into a macro. Three repetitions, and correct however llama-swap is invoked —
which matters, because a stranger will not necessarily invoke it the way the
unit does. Swapping the unit's flags would also work and was rejected: pointing
`-config-dir` at `config/` would load both contracts at once, and that file's
own header explains why 69 + 60 GiB does not fit on this machine.

Both real configs now load and list their roles: `deep fast fast-text` and
`code compact`.

## Rewriting two coupled stores

Both rewrites are done locally. Neither is pushed.

**Dolt took three attempts, and the first two failures were informative.**

`dolt filter-branch -q "delete from issues where id='...p11'"` refused with
`local changes detected on branch refs/heads/main`, while `dolt status` and the
`dolt_status` table both reported the tree clean. `--apply-to-uncommitted`
cleared that, and then failed differently: `table not found: issues`. The
traversal replays from the initial commit, where the table did not yet exist.

Passing the commit that introduced the issue as the start point fixed the
missing table but left exactly one row behind — that commit itself. The
boundary is exclusive: rewriting begins *after* the named commit, not at it.
Passing its parent finished the job. 37 versions to 0, with 36 issues and all
203 dolt commits intact.

**On the git side** an `--index-filter` dropping the matching line from
`.beads/issues.jsonl` rewrote 131 commits in three seconds. The test still
failed afterwards, correctly: `refs/original/refs/remotes/origin/master`, the
backup filter-branch writes, still carried the old blob. `git rev-list --all`
reaches it, and so would anyone who cloned. Clearing those refs is part of the
rewrite, not tidying after it.

**The count had grown while we worked.** Scoping said 10 versions of `p11`. By
the time the scrub ran it was 37, because `dolt_history_issues` gains a row per
issue per commit and this cycle added 28 commits of its own. The append-only
argument was stronger at the end than when it was made.

## A pre-existing test failure, not from this cycle

`tests/07-privileged.bats` fails its first assertion, and has since `086a320`,
which is well before this cycle opened. Nothing here touched
`docs/privileged-steps.md`.

The document has six numbered steps. The test counts reasons with
`^\*\*(Why|Superseded)\.\*\*` and undos with `^\*\*Rollback\.\*\*`, and section
6 words its two as `**Why it was added.**` and
`**Rollback — run this if the container path works:**`. Both are present; the
regexes are narrower than the prose.

So the document is not deficient and the test is too strict. Loosening a test to
make it pass is usually the wrong instinct, which is why this is being reported
rather than quietly fixed: it is outside the six items, and a repository about
to go public with a red suite is Nathan's call, not a detail to absorb.

## The scrub test reported clean while the fragments sat in HEAD

The first push went out with the git history verified only by the test that
was supposed to verify it. Cloning the result and grepping it by hand found a
hit in HEAD.

Two faults, and the first one is the one worth remembering.

**The test could not fail.** Its whole-history scan was a `run bash -c "..."`
with `$m` and `$c` interpolated through two layers of quoting. The command that
actually ran did not match anything, so the assertion passed on every input.
The same scan written by hand outside bats found the hit immediately. A test
whose escaping is wrong does not report an error — it reports success.

**The test was the last thing publishing the phrase.** It stored the search
needles as plain strings, so `tests/r06-scrub.bats` became the only file in the
repository still carrying them, one of which names a third party's source file.
The scan excluded nothing, so had it worked it would have failed on itself.

Fixed by base64-encoding the needles and decoding them at run time. That is not
obfuscation for its own sake: it means the file needs no exemption from its own
scan, which is strictly better than the exclusion `r07` had to take. The
whole-history loop was rewritten in plain bats without nested `bash -c`.

Then a second `filter-branch` replaced the file with its encoded form in every
commit that carried it, and a second force-push.

**Verified against the remote rather than the working tree**, which is what
should have happened the first time:

    fresh clone, 134 commits, every ref     -> no commit carries either needle
    dolt fetch + checkout origin/main       -> 0 hits, 36 issues, 0 p11 versions

The general lesson is not "be careful with quoting". It is that a test asserting
an absence is exactly the kind that passes when broken, because absence is what
a broken test reports too. Anything asserting a negative deserves a deliberate
red — feed it something it must find — before it is believed.
