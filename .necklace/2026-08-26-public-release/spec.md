# Make the repository publishable

No ticket. Prompted by outside interest in the Kairic Edge throughput numbers.

## The problem

The repository is private and was written for one machine. Nothing in it is
secret — a sweep of the working tree and every commit found no keys, no
credentials, and no personal data beyond a commit email that is already public
on all of them. What blocks publication is that the repository
does not work for anyone who is not Nathan, and does not say what may be done
with it.

Three specifics, each measured rather than assumed:

**It does not run elsewhere.** `scripts/setup-kairic.sh` honours
`MODELS="${MODELS:-$HOME/models}"` and then hands llama-swap a configuration
with `/home/nathan/models` compiled into it. The parameter exists and is inert:
setting it today produces a correct systemd unit pointing at a configuration
that ignores it. This is not reachable with an environment variable —
llama-swap v250 treats `${...}` as its own macro namespace and refuses to load
a configuration containing an undeclared name (`repl/envexpand.sh`).

**It does not say what it is.** There is no LICENSE, so the default is
all-rights-reserved: the people currently interested may read it and may not
legally use it. The repository description reads "Just setting up local AI
stuff on my fancy new laptop", and the agent-instruction file carries three
unfilled template prompts.

**Its publication surface is larger than its file list.** Flipping visibility
also publishes `refs/dolt/data`, which carries the issue database: 175 commits
and 1,648 historical rows against 29 current ones. Queried directly with dolt
v2.3.1, that database holds no secrets and no deleted issues — but it does hold
ten versions of a beads issue analysing a defect in a named third party's
project, and editing that issue adds an eleventh version rather than removing
the ten.

## Actors

- A stranger who finds the repository and wants to run it
- A stranger who wants to reuse part of it in their own work
- Nathan, maintaining it after publication
- The third-party projects it names

## Actor-outcome pairs

| Actor | Must be able to observe |
| --- | --- |
| Stranger running it | A clone plus one command reaches a working contract on their machine without editing any tracked file, and pointing it at a non-default model directory actually takes effect |
| Stranger running it | Any tracked configuration that cannot work alone fails immediately and by name, rather than loading and serving something wrong |
| Stranger reusing it | The terms are stated where they look first, and the parts that are not Nathan's are identified as such |
| Stranger reading the numbers | For each throughput figure in the headline comparison, they can name which upstream produced it and find that upstream, without opening a Containerfile |
| Nathan | Before the repository is public, he can see what each published ref actually contains, and has decided rather than discovered what the issue database exposes |
| Nathan | The claims the README already makes — one-command setup, 17 suites, every number measured here — are all still true afterwards |
| Third-party projects named | Their published claims are contradicted only where a shipped tool or test in this repository depends on the contradiction |

## Constraints

- llama-swap v250 defines a macro in exactly one place. Two sources setting the
  same macro to different values is a fatal conflict in both orderings, so a
  tracked default that a machine-local file overrides cannot be built
  (`repl/macro-override.sh`).
- Macros merge across files supplied by `-config` and `-config-dir` together,
  and expand inside `env:` entries as well as `cmd`
  (`repl/macro-overlay.sh`, `repl/macro-in-env.sh`).
- The systemd units already resolve every runtime path through `%h`, and the
  setup script already rewrites the repository location. Only their
  `Documentation=` metadata is literal, and it runs nothing.
- The dolt database is append-only with respect to what is already in it.
  Removing content from its history is a rewrite, not an edit.
- The repository has never been public. A history rewrite is cheap today and
  will not be cheap again.
- Beads-generated content is MIT. `necklace` is Nathan's own, already public
  under Apache-2.0 with the appendix completed and a three-line README section;
  matching it exactly keeps two of his repositories consistent.

## Approach

**Move every machine-specific value into one generated file that the repository
does not track, and let the tracked configurations reference it.** The setup
script already computes these values and already generates one file this way;
this extends that mechanism to cover the configurations rather than inventing a
second one. The tracked configurations stay the files that actually run, remain
readable on GitHub, and stop containing anyone's home directory.

This makes a tracked configuration inert on its own — it names values it does
not define. That is the intended trade. The alternative is a file that loads on
any machine and quietly serves the wrong thing, which is the failure mode this
project already writes tests against, and llama-swap's fatal-on-unknown-macro
behaviour turns the trade into a loud error rather than a silent one.

**Adopt the licence pattern already in use in Nathan's other public
repository**, and identify the generated third-party content rather than
implying the licence covers it.

**State provenance where the claim is made.** The two engines behind the
headline comparison are different people's forks, deliberately kept separate.
That is currently explained in a container definition; it belongs where the
numbers are.

**Decide the publication surface before flipping, not after.** Enumerate what
each published ref carries, and choose what the issue database does rather
than inheriting it.

**Keep third-party criticism only where something shipped depends on it.** A
documented workaround has to say what it works around. An analysis of a defect
nobody here worked around is a bug report published where its subject cannot
answer, and this project's standing policy is not to file those.

## Resolved

The three questions this document opened have been answered and are no longer
open.

The defect analysis comes out of **both histories**, not just the working tree.
The repository has never been cloned, which makes the rewrite free once and
never again.

The agent-instruction stubs become **pointers to the existing documentation**
rather than a second copy of it, so there is one place for each fact and
nothing to drift.

The repository description stays **understated**, matching the README's own
title rather than leading with a throughput figure.

---

<!--
Altitude self-check.

  Could two competent engineers read this and implement it differently, and both be right?
    Yes. Where the generated file lives, how the scrub is executed, and where
    provenance is stated are all open to them.

  Could two competent engineers read this and disagree about whether the ticket was satisfied?
    No. Every actor-outcome pair is checkable by running something.
-->
