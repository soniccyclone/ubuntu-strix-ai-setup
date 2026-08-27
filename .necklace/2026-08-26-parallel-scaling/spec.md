# Does it still hold under concurrency?

No ticket. Asked by `mathieu900v [ECO]` in Discord, reading the published figure:

> Could you try parallel 8 to see how this scales? Because mtp is not always
> great for that. Or parallel 4 realistically.

## The problem

The repository publishes 41.89 tok/s for Qwen3.8-27B and nothing about what
happens when more than one request is in flight. Every figure in `bench/` and
`docs/` is single-stream. The workload the machine actually runs is not:
`opencode-kairic.jsonc` gives subagents their own lane on slot 1, and the runner
already serves two slots for exactly that reason.

So the headline number describes a case the daily driver rarely occupies, and
the case it does occupy is undocumented.

Two claims sit behind the question, and they need separating because only one of
them is obviously true.

**Aggregate throughput should rise with concurrency.** Decode is bandwidth-bound
on weights: one stream moves the active weights to produce a single token and
leaves most of the compute idle. Measured on the 4B, holding everything else
fixed, aggregate goes 27.67 → 35.40 → 63.94 → 93.45 tok/s from one stream to
eight, while per-stream falls 28.87 → 12.32. That shape is real and the harness
can see it.

**Whether MTP survives that is genuinely open.** Speculation pays at one stream
*because* compute is idle — spare capacity drafts tokens bandwidth could not
have delivered. Concurrency supplies that arithmetic intensity by itself, at
which point drafting competes with real work and every rejected draft is waste.
The expected shape is a win that shrinks and may invert. Expected is not
measured, and this is the kind of prediction that sounds authoritative while
being wrong.

A third thing surfaced while checking the foundation. Under the conditions the
published figure was taken at, this machine now measures 49.22 and 46.03 tok/s
hot against a published 41.89, with draft acceptance landing on 76.2% — the
published value exactly. The figure is very likely stale rather than wrong: the
run behind it used a 8192 MiB prompt cache and the shipped config now uses
16384. Nathan posted that number hedging he had not vetted it. It vets, and it
undersells.

## Actors

- Nathan, answering a technically specific question in public
- Anyone running an agent against this contract, whose subagents share the slots
- `mathieu900v`, who asked a falsifiable question and deserves a falsifiable answer

## Actor-outcome pairs

| Actor | Must be able to observe |
| --- | --- |
| Nathan answering the thread | For each slot count, both what one stream feels and what the machine delivers in aggregate, each with its spread — not a single figure that hides which of the two it is |
| Nathan answering the thread | Whether MTP still pays at 4 and 8 slots, stated as a measured difference against a matched no-MTP arm rather than as a prediction |
| Nathan answering the thread | Whether the published 41.89 is reproducible, and if it has moved, what moved it |
| Anyone running an agent | What raising slots costs them in per-slot context window, and what the client configuration must be changed to at the same time |
| Anyone running an agent | Which slot count this repository recommends for agent work, and on what evidence |
| Nathan, as machine owner | What the sweep will hold and for how long before it starts, and that it releases everything afterwards |
| A reader who distrusts the numbers | The conditions of every figure, and enough method to run it themselves |

## Constraints

- `-c` is total across slots, not per-slot: `-c 8192 -np 2` gives each slot
  `n_ctx = 4096` (`repl/ctx-per-slot.sh`). Production `-np 2` is therefore
  131072 per slot, which is what the client declares. At `-np 8` it is 32768,
  against an opencode compaction reserve of 24576.
- A single measurement carries ~13% spread within one server and ~5.6% across
  launches (`repl/variance-4b.sh`). Effects smaller than that are not claims.
  Five repeats per arm is the floor.
- The published figure's conditions are specific — HumanEval 0-9, greedy, 512
  cap, reasoning off, hot cache — and the repository already documents that
  workload dominates acceptance, with code at ~76% and prose at 46-47%. A
  different prompt set produces a baseline that matches nothing published.
- `--spec-type` accepts `none`, so the no-MTP arm is a flag. It has no
  environment variable, and the runner hardcodes `draft-mtp`.
- The model holds ~48 GiB for the duration of every arm, and on this APU that
  memory is invisible to `ps`, `top` and `podman stats`. Nathan's own work
  appeared on the machine mid-cycle without announcing itself.

## Approach

**Sweep slot count against MTP state on the workload the published figure was
taken on**, so the one-slot arm has a number it must reproduce. That makes the
harness falsifiable rather than merely self-consistent, and it is the difference
between extending a published result and starting a new one that happens to
resemble it.

**Report per-stream and aggregate as two separate figures, never one.** They
move in opposite directions, and a scaling claim that does not say which it
means is unreadable. Publish the spread beside every number, because the noise
floor here is larger than the effect being measured.

**Carry draft acceptance in every row.** A speculation result without an
acceptance rate does not say whether speculation happened, and acceptance is the
mechanism the whole MTP question turns on. Include one prose arm: if MTP stops
paying under load, the regime where acceptance is already halved is where it
will be worst.

**Treat the per-slot context collapse as a finding, not a footnote.** Slots are
bought with context on this configuration. Whatever the throughput says, the
recommendation has to weigh a window a coding agent can still work in, and any
recommended slot count carries the matching client change with it.

**Ask before running, and measure the machine between arms.** The sweep is
roughly half an hour holding 48 GiB on a daily driver that has already proven it
acquires other work without warning.

## Open questions

| Question | Why it cannot be settled by reading or running |
| --- | --- |
| Should the sweep hold `-c` at the production 262144 and let per-slot context shrink, or hold per-slot context fixed and raise `-c` with the slot count? | Both are runnable and they answer different questions. Holding `-c` measures the knob Nathan would actually turn; holding per-slot context isolates concurrency from window size and is the cleaner engine result mathieu is asking about. Which one is the deliverable is a call about audience. |
| Is a recommendation in scope, or only the measurement? | The numbers may point at a slot count that is better for throughput and worse for context. Whether this cycle changes the shipped default, or only publishes what it found and leaves the decision, is Nathan's appetite rather than something the data settles. |
