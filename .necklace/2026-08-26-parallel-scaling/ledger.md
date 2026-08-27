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

## Toggle works, memory is flat, and a hint that must not be quoted

`repl/spec-toggle-np8.sh`. The shipped runner hardcodes `--spec-type draft-mtp`
and offers no environment variable, so the no-MTP arm needs a variant. One sed
against the shipped file produces `repl/run-kairic-serve-spec.sh`, differing in
exactly one line.

Three things settled:

**`--spec-type none` disables speculation cleanly** and llama-server tolerates
the `--spec-draft-*` flags remaining on the command line beside it. `draft_n`
goes 148 to 0. Had it rejected them, the arm would have needed a second runner
rather than a toggle.

**Resident memory does not grow with slots.** 47 GiB at `-np 1`, 47 at `-np 2`,
46 at `-np 8`. `-c` being total is why: the KV allocation is fixed and the slots
divide it. Confirmed by `slot_ctx` reading 262144 / 131072 / 32768 across those
three. Eight arms holding a constant ~47 GiB is a much easier thing to promise
Nathan than one that grows.

**And a number that looks like an answer and is not one:**

    spec-type=draft-mtp  np=2  draft_n=148  accept=58.8%  aggregate=10.71 tok/s
    spec-type=none       np=2  draft_n=0                  aggregate=17.13 tok/s

MTP off measuring 60% faster is exactly the shape mathieu predicted, which is
precisely why it should not be repeated anywhere. It is disqualified three times
over: the generic mixed prompt set rather than the HumanEval slice, a 64-token
cap where startup dominates and steady-state decode barely happens, and a single
sample against a 13% noise floor. Its only valid readings are that the toggle
works and that the question is live.

Writing it down because a plausible number that agrees with a prediction is the
easiest kind to start quoting by accident.

## Three assertions corrected before they were written down

Checking the CUJ's own claims against the measurements caught three tests that
would have been wrong.

**A one-point tolerance on draft acceptance would have been flaky.** The 76.2%
match against the published figure is striking, and the temptation was to pin
it tightly. But the same run's second hot pass gave 74.2% — a 2.0pp spread with
nothing changed. A one-point assertion would fail on a perfectly good run. The
regime, 70-80%, is what is actually stable.

**A test reading "the client's declared context" would have passed for the wrong
reason.** `opencode-kairic.jsonc` declares two: `code` at 131072 and `compact`
at 262144. Only the first pairs with the slot count. A test asking whether the
per-slot window appears among the declared contexts is satisfied by `compact`
regardless of what `code` says, which is precisely the drift it exists to catch.

**The cited-versus-measured precedent is looser than described.**
`bench/media-timings.tsv` has no dedicated column; `m08-timings.bats` greps a
free-text notes field for "this box" against "published" or "reference". That
works and is enforced, but calling it a precedent for a marked field overstated
it. Recorded as-is, with the note that a real column would be firmer.

All three share a shape with the failures the release cycle produced: an
assertion narrower or looser than the thing it claims to cover, which passes
without proving anything.

## The sweep ran for 37 minutes after being stopped

Stopping the background task reported success. It killed the wrapper, not the
script: `bash ./bench/parallel-sweep.sh` kept running as its own process,
launched further arms, and was found 37 minutes later holding 45 GiB with
`--spec-type none -np 8` — an arm nobody was waiting for, on a machine that had
been told the run was over.

It surfaced by accident. A dry run printed `[REFUSED] need 60 GiB of GTT free,
found 56` and the refusal was correct, which is the only reason anyone looked.
Had the sweep been between arms at that moment, the check would have passed and
the runaway would have kept going.

Two things this says, and the first is not the interesting one.

**A trap cannot help on SIGKILL.** `trap ... EXIT INT TERM` is right and it
fired correctly every other time this cycle. It cannot fire when the process is
killed outright, and no amount of care in the script changes that.

**So the recovery path has to exist outside the script.** `make stop-all` is
that path and it did not know the name `kairic-sweep`, because the sweep was
new and the target's list is hand-maintained. A leak with no way to reap it
short of knowing podman is exactly the situation this repository has a rule
about.

Fixed by adding the container to `stop-all` and by a test that derives the
names from what the repository can actually launch — literal `--name` flags
plus names held in a `CTR` variable, since the sweep uses the latter and a
literal-only scan misses precisely the container that leaked. Verified it goes
red when the name is removed again.

The CUJ-06 tests were green throughout. They asserted the trap existed, which
was true and insufficient. What was missing was an assertion about what happens
when the trap cannot run.

## Validating the analysis tests, and nearly destroying the run doing it

The tests that read the results record cannot be trusted until something has
exercised them, and the record does not exist until the sweep finishes. So a
synthetic twelve-row record was built to drive them.

**Which found two real test defects.** The row-count guards said 13 — written
when the plan had thirteen arms, and stale the moment one was dropped to twelve.
Every record test failed against a perfectly well-formed record. Now derived by
counting arms in the sweep script itself, so it cannot drift again. And the
inconclusive test read `docs/parallel-scaling.md` literally while everything
else took an override, so it was testing a file that did not exist.

**And it nearly cost the run.** The fixture was written straight over
`bench/parallel-scaling.tsv` — the file the running sweep appends to, one arm at
a time. Twelve synthetic rows replaced the single real one. Recovered because
the synthetic rows carried a spread of exactly 9.0 and the real one did not, so
they could be told apart; the real row was restored and nothing was lost.

That was luck, not method. The tests now take `REC` and `WRITEUP` overrides so a
fixture never goes near live output, which is what should have been true before
the first fixture was written.

The general shape is familiar by now: a test that cannot fail proves nothing, and
a test nobody has watched fail is in that category until proven otherwise. The
new part is that *checking* a test can itself be destructive, and a background
job's output file is exactly the wrong place to check one.

## "--spec-type none" does not mean no speculation

The sweep's second arm recorded `spec_type=none` and `draft_n=7168`. Both
cannot be true, and the earlier probe that "verified" the toggle had shown
draft_n going 148 to 0.

`repl/mtp-off-really.sh` settles it. With `--spec-type none` the server still
reports:

    common_speculative_init: adding speculative implementation 'ngram-mod'
    common_speculative_impl_ngram_mod: initialized ngram_mod with n_match=24

and drafting depends entirely on the workload:

    prose, 64 tokens        draft_n=0
    prose, 512 tokens       draft_n=0
    humaneval, 512 tokens   draft_n=128   accepted=98

**The earlier probe used prose.** An n-gram speculator finds nothing to match in
discursive text and a great deal to match in code, so it reported zero, and I
read that as the flag working. It was the workload, not the flag — the same
mistake this cycle already caught once, when a mixed prompt set would have put
the baseline between two regimes. Twice now the workload has been the variable
while something else got the credit.

**What it means for the experiment.** `--kairic-edge` brings its own speculative
stack, and `--spec-type` selects what joins it rather than whether speculation
happens. So the two arms are not MTP against nothing. They are:

    draft-mtp   MTP plus the kairic-edge default stack
    none        the kairic-edge default stack alone (ngram-mod)

That is still the comparison mathieu asked for — it isolates what MTP adds over
what the engine would do anyway — but it must be labelled as that and not as
"MTP off". A row saying `none` with seven thousand drafted tokens is not a
mislabelled number, it is a claim nobody can check.

The sweep now records the speculative implementations the server actually
initialised, per arm, read from its own startup log. An arm that describes
itself cannot be quietly wrong about what it ran.

The CUJ-02 test asserting `none` rows carry `draft_n=0` was correct to fail and
is now wrong in its premise. Replaced: the arms must differ in `spec_type`, and
each must record which implementations it loaded.

## The instrumentation pays for itself on the first two arms

    np1-mtp    spec_type=draft-mtp  spec_impls=draft-mtp+ngram-mod  draft_n=8316
    np1-nomtp  spec_type=none       spec_impls=ngram-mod            draft_n=7168

`draft-mtp` loads both implementations; `none` loads ngram-mod alone. The record
now demonstrates the thing the ledger asserts, rather than asking a reader to
trust the prose. That is the whole point of the column.

**And an unplanned observation worth carrying into the writeup:** the two arms
have very different stability.

    np1-mtp    per-stream ±6.3%   aggregate ±8.1%
    np1-nomtp  per-stream ±14.9%  aggregate ±16.6%

The MTP arm sits comfortably inside the 13% noise floor; the ngram-only arm sits
above it. Speculation by n-gram matching depends on how much of the output the
matcher has seen before, and that varies far more between HumanEval problems
than MTP's learned prediction does. So the comparison arm is not merely slower,
it is less repeatable — which matters when the question is whether a gap is real.

Not yet established across other slot counts. If it holds, any verdict against
the ngram-only arm carries a wider band than a naive reading of the noise floor
would suggest, and the report's verdict function already accounts for that by
using the mean of both arms' spreads rather than a fixed threshold.

## The answer, and being wrong on the way to it

MTP pays at every slot count measured, including eight and including prose. The
question anticipated the opposite and that is what makes the result worth
sending back.

| slots | with MTP | without | gap | band | verdict |
| ---: | ---: | ---: | ---: | ---: | --- |
| 1 | 46.64 | 31.21 | +39.6% | ±12.4% | MTP faster |
| 2 | 46.33 | 37.72 | +20.5% | ±13.6% | MTP faster |
| 4 | 48.20 | 42.53 | +12.5% | ±16.6% | inconclusive |
| 8 | 63.13 | 51.37 | +20.5% | ±11.7% | MTP faster |
| 8 prose | 33.93 | 26.82 | +23.4% | ±20.0% | MTP faster |

**I called it wrong twice while the arms were landing, both times toward the
expected answer.** After three points I described aggregate throughput as flat
across slot counts; it was flat for one to four and rose 1.35x at eight. Then I
framed MTP as becoming "redundant" under concurrency, and the eight-slot pair
gave it a clear twenty percent.

The verdict function did its job on the document. It could not do anything about
running commentary, and the gap between the two is the lesson: the discipline
that stops a writeup overclaiming has to be a property of the tooling, because
it is demonstrably not a property of the person watching numbers arrive one at a
time with a hypothesis already in mind.

The four-slot `inconclusive` is honest rather than a gap in the story. That arm's
comparison partner carried ±21.5%, the widest spread of the sweep, and a 12.5%
difference cannot be resolved against it.

## The hypothesis that died

`np1-mtp` 46.64 against `np1-cache8192` 46.01: 1.4% apart inside a ±8.9% band.
Prompt cache size makes no detectable difference on this workload, so the
explanation offered earlier for the published 41.89 reading low — that the run
behind it used 8192 where the shipped config uses 16384 — is measured and wrong.

The gap is now unexplained. The remaining candidate is the task subset, ten tasks
against a pool of eight, and it is recorded as a hypothesis rather than promoted
to a cause because that is precisely the move that just failed.

## Where the noise lived

The no-MTP arms were consistently less repeatable than the MTP arms, and got
worse with concurrency: ±16.6%, ±18.8%, ±21.5%, ±14.4%. N-gram speculation
depends on matching text it has already seen, which varies more between problems
than a learned predictor does.

The prose arms' per-stream figures are unusable — ±52.2% and ±45.8%. Prose runs
to the full token cap where HumanEval completions stop early at around 162
tokens, so a prose pass is roughly three times the work and per-request rates
scatter badly under eight-way interleaving. Their aggregates are stable and are
what the writeup uses; the per-stream figures are named as not quotable rather
than printed with a decimal point.

## The recommendation was right about throughput and wrong about the premise

Nathan reported hitting compaction mid-research while writing a plan document,
on a model with a 262144-token window. The arithmetic explains it exactly:

    262144  native window
    131072  divided by two slots
    106496  less opencode's 24576 compaction reserve   <- trigger
     73728  less 32768 output reserve                  <- actual working room

His peak session measured **107,257 tokens** against a computed trigger of
106,496. Not close to it; on it.

**The second slot existed for a lane that was never used.** opencode's own
session database, 590 assistant messages:

    code        585
    compact       3
    code-sub      2

Half the context window was reserved for 0.3% of the traffic. The reasoning
behind two slots was sound — a subagent call on one slot evicts the session's KV
and forces a full re-prefill — and the premise was never checked against what
opencode actually did.

This document had recommended two slots on that premise a few hours earlier. The
sweep's throughput numbers were not wrong and did not change; what changed is
that the context cost is now weighed against measured usage rather than against
an imagined subagent workload.

Nathan added the argument that settles it independently of usage: eight slots
buys 1.35x aggregate while making each agent 5.4x slower, and this is a
single-agent machine. Aggregate throughput is the wrong objective function here.

**Changed:** `KAIRIC_SLOTS` 2 to 1, opencode `limit.context` 131072 to 262144,
and the `code-sub` entry removed — it pinned `id_slot: 1`, a slot that no longer
exists. Verified on the production path: `n_slots = 1`, `new slot, n_ctx =
262144`, contract answers, 47 GiB resident.

Working room goes 73728 to 204800, 2.8x.

**Two tests replaced rather than repaired.** They pinned the shipped slot count
and context as literals, under the heading "unchanged by this cycle", and broke
the moment the recommendation changed. A literal was the wrong shape: what has
to hold is that the configuration and the published recommendation agree,
whichever number they settle on, and that no client model pins a slot the server
does not have. Both were verified to fail when reintroduced.

## The empty thinking blocks were the 4B, not the 27B

Nathan reported opencode rendering empty `<think></think>` blocks above replies.
The repository already believed this fixed: `00557ba` moved the 27B from
`--reasoning off --reasoning-format none` to `on`/`deepseek`, and the runner
carries a comment explaining that `none` "leaves whatever tags appear unparsed
inside message.content -- which is how you get empty <think></think> rendered as
literal text".

The evidence was in opencode's own SQLite store: 497 stored message parts
containing the literal tags, 496 before that commit and one after. The service
restarted at 09:44, five minutes after the fix, so the survivor was not a stale
container — the first hypothesis, and wrong.

Joining the part to its message named the culprit:

    modelID=compact  agent=compaction  role=assistant

**The 27B was fixed and the 4B beside it was not.** `llama-swap-kairic.yaml`
still launched the compaction worker with `--reasoning off --reasoning-format
none`. The symptom looked random because it only appears when compaction, title
or summary runs — every one of which is routed to that model.

Reproduced through the contract, then isolated on a standalone 4B:

    reasoning=off  format=none      think-in-content=True   reasoning=0
    reasoning=off  format=deepseek  think-in-content=False  reasoning=0
    reasoning=off  format=auto      think-in-content=False  reasoning=0

`--reasoning off` is right for compaction and is not the problem. The two flags
are independent, and only the format decides whether the template's non-thinking
marker gets parsed. Fixed to `deepseek`, verified end to end.

**The lesson is about how the fix was recorded.** The original commit fixed one
model and wrote the explanation into that model's runner, where the next reader
of the *other* model's config would never see it. A comment is not a constraint.
`tests/p08-reasoning.bats` now fails if any model in `config/` is served with
`--reasoning-format none`.

**And a third self-matching test in one session.** The first draft of that test
flagged `run-kairic-serve.sh`, because its comment quotes the bad flag while
explaining why not to use it. Config comments are stripped before scanning now.
Three times is a pattern rather than bad luck: any test that greps for a
forbidden string will find the prose explaining why it is forbidden.
