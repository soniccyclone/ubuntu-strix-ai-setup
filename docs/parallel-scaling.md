# Concurrency: does the 27B still hold up with more than one request in flight?

Every throughput figure this repository published before now was single-stream.
The workload it actually runs is not: opencode gives subagents their own lane,
and the contract serves two slots for that reason.

Prompted by a question from `mathieu900v [ECO]`, who read the published 41.89
tok/s and asked the right thing — try four or eight parallel, because MTP
speculation is not always great under concurrency.

The short answer is that on this hardware it is. MTP pays at every slot count
measured, including eight, and including the workload where it has least to work
with. That is not the answer the question expected, and it is the more useful one.

## What was measured

Twelve arms, ~47 GiB resident each, `bench/parallel-sweep.sh`. Each arm is five
repeats of a pass over a fixed pool of eight HumanEval tasks, greedy, 512-token
cap, reasoning off, with one warming pass discarded — the conditions the
published figure was taken under. Every figure carries the peak-to-peak spread
across its repeats.

**The spread matters more than usual here.** A single measurement on this machine
carries roughly 13% spread, which is larger than several of the differences
being asked about. Where a gap falls inside the combined spread of its two arms,
the tables below say `inconclusive` rather than naming a winner. The tables are
generated from `bench/parallel-scaling.tsv` by `tools/parallel_report.py`, so
every number here is the number in the record.

## How throughput scales with slots

| slots | per-slot ctx | per-stream tok/s | aggregate tok/s | vs 1 slot | draft accept |
| ---: | ---: | ---: | ---: | ---: | ---: |
| 1 | 262,144 | 51.29 ±6.3% | 46.64 ±8.1% | 1.00x | 72.8% |
| 2 | 131,072 | 29.28 ±9.5% | 46.33 ±8.4% | 0.99x | 74.0% |
| 4 | 65,536 | 15.01 ±11.8% | 48.2 ±11.6% | 1.03x | 76.7% |
| 8 | 32,768 | 9.44 ±4.6% | 63.13 ±8.9% | 1.35x | 77.8% |

## Does MTP still pay?

| workload | slots | with MTP | without | difference | verdict | accept | stack (with / without) |
| --- | ---: | ---: | ---: | ---: | --- | ---: | --- |
| humaneval | 1 | 46.64 ±8.1% | 31.21 ±16.6% | +39.6% | MTP faster | 72.8% | `draft-mtp+ngram-mod` / `ngram-mod` |
| humaneval | 2 | 46.33 ±8.4% | 37.72 ±18.8% | +20.5% | MTP faster | 74.0% | `draft-mtp+ngram-mod` / `ngram-mod` |
| humaneval | 4 | 48.2 ±11.6% | 42.53 ±21.5% | +12.5% | inconclusive | 76.7% | `draft-mtp+ngram-mod` / `ngram-mod` |
| humaneval | 8 | 63.13 ±8.9% | 51.37 ±14.4% | +20.5% | MTP faster | 77.8% | `draft-mtp+ngram-mod` / `ngram-mod` |
| prose | 8 | 33.93 ±16.4% | 26.82 ±23.5% | +23.4% | MTP faster | 57.0% | `draft-mtp+ngram-mod` / `ngram-mod` |

## Controls

- **Prompt cache 16384 vs 8192 MiB**, one slot, everything else equal: 46.64 against 46.01 tok/s aggregate (+1.4%, inconclusive).
- **Per-slot window 262144 vs 32768**, one slot, everything else equal: 46.64 against 41.96 tok/s aggregate (+10.6%, larger window faster). This bounds how much the shrinking window confounds the slot sweep.

## Two things that are not obvious

**`-c` is total across slots, not per slot.** `-c 8192 -np 2` gives each slot an
`n_ctx` of 4096. So the shipped `-c 262144 -np 2` is 131072 per slot, which is
what `config/opencode-kairic.jsonc` declares for the `code` model. Raise the
slot count and that pairing silently stops being true: four slots is 65536 each,
eight is 32768. **opencode reserves 24576 of that for compaction**, so eight
slots leaves a coding agent roughly 8k of working context. Slots are bought with
context on this configuration, and opencode's `limit.context` has to move at the
same time or the client is declaring a window it does not have.

**`--spec-type none` does not disable speculation.** The `--kairic-edge` path
loads `ngram-mod` regardless — the server says so in its own startup log — and
that drafts freely on code while finding nothing in prose. So the comparison
above is *MTP plus the default stack* against *the default stack alone*, not MTP
against nothing. Each row records the implementations the server actually
initialised, in the `spec_impls` column, so the arms describe themselves rather
than relying on their labels.

## Reading the tables

Aggregate throughput is flat from one to four slots and climbs at eight. MTP
saturates the spare compute at low concurrency, so the second and fourth streams
buy nothing; by eight there is enough demand to exceed what drafting was
absorbing. Without MTP the same sequence climbs steadily from a lower start
(+65% across the range against +35%) and never catches up.

Per-stream throughput falls roughly as you would expect from dividing a fixed
machine: 51.29, 29.28, 15.01, 9.44.

**The prose per-stream figures are not quotable.** Prose runs to the full token
cap on every request where HumanEval completions stop early, so a prose pass is
about three times the work and the per-request rates scatter under eight-way
interleaving — ±52% and ±46%, several times the noise floor. Their aggregates
are stable and are what the table uses.

## What the published 41.89 turned out to be

Under its own conditions this machine measures 46-49 tok/s hot, with draft
acceptance landing on 76.2% — the published value to the decimal, which is the
strongest evidence the two are the same measurement.

The obvious explanation was that the published run used an 8192 MiB prompt cache
where the shipped config now uses 16384. **That was measured and it is wrong**:
46.64 against 46.01, a 1.4% gap inside a ±8.9% band. Prompt cache size makes no
detectable difference on this workload.

So the throughput gap is unexplained. The most likely remaining candidate is the
task subset — the published run used all ten HumanEval tasks and these arms use
a fixed pool of eight — but that is a hypothesis, not a finding, and it is
recorded here as one.

## Recommendation

**This repository recommends one slot for agent work**, and ships that. The
sweep above measures the throughput side; the session log settles the rest.

- **Aggregate throughput is flat from one to four slots** (46.64, 46.33, 48.20
  tok/s, all inside each other's spread). The first three slots buy no more
  tokens per second from the machine. Eight buys 1.35x — and costs 5.4x in
  per-stream rate, 51.29 down to 9.44 tok/s. For interactive work that is a bad
  trade at every step.
- **Slots are bought with context.** `-c` is total, so two slots is 131072 each
  and eight is 32768. opencode then reserves 24576 for compaction and 32768 for
  output, so two slots leaves **73728 tokens of working room** out of a
  262144-token model, and eight leaves about 8k. That is not a working agent.
- **One slot gives the session all 262144**, which is 204800 of working room
  after the same reservations — 2.8x more than two slots.

The earlier revision of this document recommended two slots, reserving the
second for opencode's subagent lane so a subagent call could not evict the main
session and force a full re-prefill. That reasoning was sound and the premise
was not: **the lane was used twice in 590 assistant messages.** Half the context
window was being held for 0.3% of the traffic, and plan-doc research was hitting
compaction mid-run at 107257 tokens against a trigger at 106496.

Subagents now share the single slot and contend with the session. At two uses in
590 that is the right trade rather than a tolerated one.

**Eight slots remains the right choice for a batch workload** that wants total
tokens and does not need context or latency. That is not what this contract is
for.

## Reproducing

```
make setup                    # checks bats, jq, podman, dolt
bench/parallel-sweep.sh       # 12 arms, ~90 minutes, ~47 GiB resident
```

It reads free GPU memory from the amdgpu GTT node before every arm and refuses
rather than competing — on this APU the weights live in GTT and `ps`, `top` and
`podman stats` all report a 47 GiB model as approximately nothing. Every arm
stops its own container on exit, interrupt or failure, and `make stop-all` reaps
it if something kills the script outright.

Full method, the wrong turns, and what each probe settled:
`.necklace/2026-08-26-parallel-scaling/`.
