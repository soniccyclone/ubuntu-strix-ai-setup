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
