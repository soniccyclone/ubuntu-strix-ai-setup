# Ledger — concurrent-slot scaling and whether MTP still pays

Started 2026-08-26. No ticket. Prompted by `mathieu900v [ECO]` in Discord,
reading the published figure:

> That's really good, i was on vacation few days and didn't expect a 27B to run
> this good on Strix halo! Could you try parallel 8 to see how this scales?
> Because mtp is not always great for that. Or parallel 4 realistically.

This is the first outside scrutiny the numbers have had, and Nathan's own
framing when he posted them was that he had not hard-core vetted them yet.

## What the request maps onto

`-np` in the runner, already parameterised as `KAIRIC_SLOTS` and set to 2.

Two separate claims are being asked about and they want separating:

1. **Does aggregate throughput scale with concurrency?** Decode is bandwidth
   bound on weights. At one stream you move the active weights to produce a
   single token, leaving most of the compute idle. At N streams you move them
   once for N tokens, so aggregate should climb until something else binds.

2. **Does MTP survive that?** Speculation pays at batch 1 precisely *because*
   compute is idle — spare FLOPs draft and verify tokens bandwidth could not
   have delivered anyway. Raise concurrency and the batch supplies its own
   arithmetic intensity; speculation then competes with real work and rejected
   drafts are waste. The expected shape is a win that shrinks with `-np` and may
   invert. That is what "mtp is not always great for that" means.

Both are predictions. Neither is measured here yet, and the second one is the
kind that sounds authoritative and is wrong often enough to be worth running.

## Machine pre-flight

Before allocating anything on Nathan's daily driver, 2026-08-26 21:01 CDT:

    memory     15 GiB used, 107 available of 122
    GTT        2 GiB used of 110
    services   none of this project's running
    load       6.90 (firefox and the tail of the release cycle's test runs)

Headroom is fine. The 27B is ~46 GiB at load and was observed climbing to
~91 GiB used after real work.

## `-c` is total across slots — confirmed, not assumed

`repl/ctx-per-slot.sh`, on the 4B because these are llama.cpp semantics rather
than Kairic ones and 4 GiB answers in seconds where 46 GiB does not. Launched
with `-c 8192 -np 2`:

    srv  load_model: initializing slots, n_slots = 2
    slot load_model: id  0 | task -1 | new slot, n_ctx = 4096
    slot load_model: id  1 | task -1 | new slot, n_ctx = 4096

So the production `-c 262144 -np 2` is 131072 per slot, which is exactly what
`opencode-kairic.jsonc` declares. That pairing is correct today and silently
becomes a lie at any other `-np`: 4 gives 65536 per slot, 8 gives 32768. On a
model advertising a 262144 window, `-np 8` leaves each agent 32768 — and
opencode reserves 24576 of it for compaction.

That is the part of mathieu's suggestion that is not a free knob turn, and he
had no way to know it.

## The harness works, and the shape is real

`repl/conc-harness.py` fires N concurrent completions and reports per-stream
tok/s (what one user feels, which falls) beside aggregate (what the machine
delivers, which rises). Reporting one without the other is how a scaling claim
becomes meaningless.

Validated on the 4B, `-c` held at 262144 so per-slot shrinks as `-np` rises:

| streams | aggregate tok/s | per-stream tok/s | wall for the batch |
| ---: | ---: | ---: | ---: |
| 1 | 27.67 | 28.87 | 4.63 s |
| 2 | 35.40 | 18.60 | 7.23 s |
| 4 | 63.94 | 17.26 | 8.01 s |
| 8 | 93.45 | 12.32 | 10.96 s |

3.4x aggregate at eight streams, per-stream down to 43%. That is the shape
mathieu predicted, on a model with no MTP at all — `draft_n` is 0 in every row,
which also confirms the field is present and will mean something on the 27B.

## The noise floor is larger than the effect we were sent to measure

The context-size arm returned 26.23 and 28.87 tok/s for a change that cannot
affect decode rate. That prompted `repl/variance-4b.sh`, and the result inverted
my expectation:

    WITHIN one server, 5 measurements     mean 28.21  sd 1.48  spread 13.3%
    ACROSS 5 launches, 1 measurement each mean 27.94  sd 0.66  spread  5.6%

I expected the opposite — that model load and memory placement would dominate
and repeated measurements against one warm server would be tight. Relaunching
is the *tighter* of the two.

Cause not established. The harness warms with one request before measuring, and
repeated identical prompts against a live server interact with the prompt cache,
so the within-server repeats are not independent in the way across-server ones
are. Worth knowing, not worth chasing here.

**What it settles:** a single measurement carries roughly 13% spread, which is
larger than the MTP effect this cycle exists to detect. Any arm reported from
one run is noise wearing a decimal point. With sd ≈ 1.48 on a mean of 28, five
repeats give a standard error near 0.66, enough to separate a 10% difference
with room to spare. Five is the floor, and every published figure needs its
spread beside it.

## The benchmark has to run the same workload, or the baseline floats

`--spec-type` takes `none`, so the MTP-off arm is a clean flag rather than a
build. Worth noting that llama.cpp's default for it *is* `none` — the runner
opting into `draft-mtp` is a deliberate choice, not an inherited default. There
is no environment variable for it, so the shipped runner needs the same
`KAIRIC_SLOTS`-style toggle it already has for slots.

More important, and nearly missed: the conditions behind 41.89 are specific.
HumanEval tasks 0-9 chat-adapted, greedy, 512-token cap, reasoning off,
compatibility mode, **hot** prompt cache. `docs/kairic-operations.md` already
records that the workload dominates the result:

> Draft acceptance tracks how predictable the output is. Code accepts ~76% and
> runs at 41-57 tok/s. Discursive prose accepts 46-47% and runs at 16-21.

My first harness used a deliberately mixed prompt set — page faults, a red-black
tree, drum memory, a TCP handshake. Two of those four are discursive prose. That
set would have produced an acceptance rate somewhere between 46% and 76% and a
rate somewhere between 16 and 57, and the `-np 1` arm would not have matched the
published figure at all. Every scaling ratio would then be measured against a
baseline that does not correspond to anything published, while looking perfectly
respectable.

The sweep reuses the HumanEval slice the published figure was taken on. Its
`-np 1` arm has a number it must reproduce, which makes the harness itself
falsifiable rather than merely self-consistent.

The generic-prompt harness is not wasted — a prose arm is worth one row, because
acceptance is what MTP's value rides on and prose is where acceptance already
collapses. If MTP stops paying under concurrency, prose at `-np 8` is where it
will be worst.

## The published figure reproduces — and is beaten by its own repository

`repl/baseline-27b.sh`, matched to the conditions behind 41.89: HumanEval 0-9,
greedy, 512 cap, reasoning off, compatibility mode, `-np 1`, cold pass first and
discarded.

| pass | measured | published | draft accept |
| --- | ---: | ---: | ---: |
| cold | 30.00 | 28.41 | 70.8% |
| hot | **49.22** | **41.89** | 76.2% |
| hot again | 46.03 | — | 74.2% |

Draft acceptance lands on 76.2% — the published value to the decimal — which is
the strongest evidence the two runs are the same measurement. Cold is within
5.6%. Hot is 10-17% *above* what the repository claims.

The two hot passes differ from each other by 6.5%, comfortably inside the 13%
noise floor from `variance-4b.sh`, so neither is quotable alone.

**The leading explanation is that the published figure is stale rather than
wrong.** The run that produced it used `--cache-ram 8192`; the shipped config
now uses `16384`, raised deliberately during the release cycle because agent
turns reuse thousands of tokens of prefix. Hot throughput is exactly what a
larger prompt cache should move. Same `-np 1` in both, so slots are not it.

Not established — attributing it needs the A/B, which is one arm of the sweep
rather than a separate errand. Recorded as a hypothesis, not a conclusion.

What it means for the Discord thread: Nathan hedged that he had not vetted the
number. It vets. The acceptance rate is exact, and the throughput figure is
conservative against his own current configuration.

## Nathan's machine is not idle any more

Mid-cycle, `podman ps` showed `ghcr.io/soniccyclone/lodestone-upstream` started
21 seconds earlier. Not this project's, not started here.

At the time of checking it had not taken GTT (2 GiB used of 110, 105 GiB of RAM
available), so the baseline run was unaffected. But the full sweep is eight arms
holding ~48 GiB for roughly half an hour, and the rule this repository already
learned the hard way is that process-level tools report a unified-memory model
as approximately nothing. Whatever lodestone grows into will not appear in
`podman stats` either if it touches the GPU.

The sweep asks Nathan before it runs, and reads GTT between arms rather than
assuming the headroom it measured at the start is still there.

## Nathan's answers

**Hold the production knob, and bound the confound.** `-c` stays at 262144 while
per-slot context shrinks with the slot count, plus a spot-check at one slot with
the window pinned to the eight-slot value. Rejected: holding per-slot context
fixed throughout, which is the cleaner engine result mathieu is nominally asking
for but produces no arm corresponding to a configuration anyone would run. The
spot-check recovers most of that answer for two arms.

**Measure and recommend, do not change the default.** Slots cannot move without
opencode's `limit.context` moving with them, and that pairing is a decision.
