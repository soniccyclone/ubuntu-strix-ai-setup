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
