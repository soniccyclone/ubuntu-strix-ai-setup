# CUJ document: Does it still hold under concurrency?

Derived from `spec.md` in this directory. One CUJ per actor-outcome pair.

Test files follow the existing convention: bats, one file per CUJ, prose test
names. Earlier cycles used `NN-`, `mNN-` and `rNN-`; this one uses `pNN-`.

The sweep writes `bench/parallel-scaling.tsv`, following the precedent
`bench/media-timings.tsv` set — one row per arm, mandatory columns, and a test
that fails when a row omits what makes it reproducible.

Most of these tests assert properties of the harness and the record rather than
re-running the hour-long sweep. A test that needs 47 GiB and an hour is a test
nobody runs.

---

## CUJ-01: Nathan reads what one stream feels and what the machine delivers, separately

**Actor:** Nathan, answering the thread
**Trigger:** the sweep finishes and he needs a table he can paste
**Journey:**

1. Nathan opens the results record.
2. Each slot count shows per-stream throughput and aggregate throughput as two columns.
3. Each carries the spread across repeats, so he can see which differences are real.

**Tests to create:**

| Test | Input | Assertion | Informed by |
| --- | --- | --- | --- |
| `every row carries both per-stream and aggregate throughput` | the results record | no row has one populated and the other empty | REPL: the two move in opposite directions — 4B went 28.87→12.32 per-stream while aggregate went 27.67→93.45 |
| `every row carries the spread across its repeats` | the results record | each row names its repeat count and a spread, and the repeat count is at least 5 | REPL: `variance-4b.sh` — 13.3% within-server spread, larger than the effect being measured |
| `the harness reports both figures from one concurrent batch` | a batch of N concurrent requests against a live server | aggregate is computed from total tokens over batch wall time, not by summing per-request rates | REPL: summing per-request rates double-counts overlapped time and inflates aggregate |

**Done when:** the three tests above pass. All must be red when created.

**Beads:** `ubuntu-strix-ai-setup-88a`

---

## CUJ-02: Nathan can say whether MTP still pays at four and eight slots

**Actor:** Nathan, answering the thread
**Trigger:** mathieu's specific claim that "mtp is not always great for that"
**Journey:**

1. Nathan reads a row for each slot count with speculation on, and a matched row with it off.
2. The two rows differ in exactly one setting.
3. Draft acceptance appears beside every speculation-on row.
4. The difference is stated against the measured spread, so "no change" is distinguishable from "too small to see".

**Tests to create:**

| Test | Input | Assertion | Informed by |
| --- | --- | --- | --- |
| `each MTP arm has a matched no-MTP arm differing only in spec type` | the results record | for every slot count, an on and an off row exist whose other recorded conditions are identical | REPL: an earlier cycle's bench gave one arm draft flags the other lacked, which is how a comparison stops being one |
| `speculation-on rows carry a draft acceptance rate` | the results record | every row with speculation enabled reports draft_n and an acceptance percentage; every off row reports draft_n of zero | REPL: `--spec-type none` drives draft_n from 148 to 0, so the field distinguishes the arms |
| `a difference smaller than the measured spread is not reported as a difference` | two arms whose means differ by less than their combined spread | the record marks that comparison inconclusive rather than stating a winner | REPL: two hot passes of the same config differed 6.5% with nothing changed |

**Done when:** the three tests above pass. All must be red when created.

**Depends on:** CUJ-01

**Beads:** `ubuntu-strix-ai-setup-8iy`

---

## CUJ-03: Nathan can say whether the published figure still holds, and what moved it

**Actor:** Nathan, answering the thread
**Trigger:** he posted 41.89 hedging that he had not vetted it
**Journey:**

1. Nathan reads the one-slot arm, taken under the published figure's own conditions.
2. It reproduces, or it does not, against a recorded expectation rather than a memory.
3. Where it has moved, the record names the configuration change responsible rather than guessing.

**Tests to create:**

| Test | Input | Assertion | Informed by |
| --- | --- | --- | --- |
| `the single-slot arm records the conditions the published figure was taken under` | the results record | the one-slot row names workload, sampling, token cap, reasoning state and cache warmth | REPL: 41.89 is HumanEval 0-9, greedy, 512 cap, reasoning off, hot — a different prompt set lands anywhere between 16 and 57 |
| `draft acceptance on the single-slot arm lands in the published regime` | the one-slot speculation-on arm | acceptance is between 70% and 80% | REPL: hot passes measured 76.2% and 74.2%, cold 70.8%. The 76.2% match is striking but its own spread is 2.0pp, so a one-point tolerance would fail on a good run |
| `the cache-ram comparison is recorded as measured or absent, never as an assumption` | the results record | either a row pair differing only in cache-ram exists, or no claim about cache-ram appears in the writeup | REPL: hot measured 46-49 against a published 41.89; the 8192→16384 change is the hypothesis, not the finding |

**Done when:** the three tests above pass. All must be red when created.

**Beads:** `ubuntu-strix-ai-setup-coz`

---

## CUJ-04: Someone running an agent sees what slots cost them in context

**Actor:** anyone running an agent against this contract
**Trigger:** they read the sweep and consider raising slots
**Journey:**

1. They see the per-slot context window each slot count leaves them.
2. They see it against opencode's compaction reserve, so they can tell what is left to work in.
3. They find the client setting that must change at the same time, named explicitly.

**Tests to create:**

| Test | Input | Assertion | Informed by |
| --- | --- | --- | --- |
| `every slot count in the record names its per-slot context window` | the results record | each row's per-slot window equals total context divided by its slot count | REPL: `-c 8192 -np 2` gives each slot n_ctx 4096; confirmed again at 262144/131072/32768 for np 1/2/8 |
| `the coding model's declared context equals the per-slot window` | `config/llama-swap-kairic.yaml`, `config/run-kairic-serve.sh`, `config/opencode-kairic.jsonc` | the `code` entry's context equals total context divided by the runner's slot count | REPL: verified 262144/2 = 131072 = the `code` limit. The client declares two contexts and `compact` is 262144, so a test reading every declared limit passes for the wrong reason |
| `the writeup names the client setting that moves with slots` | the writeup | it names opencode's context limit as a required simultaneous change, not a consequence | |

**Done when:** the three tests above pass. All must be red when created.

**Beads:** `ubuntu-strix-ai-setup-wos`

---

## CUJ-05: Someone running an agent finds a recommended slot count and the evidence for it

**Actor:** anyone running an agent against this contract
**Trigger:** they finish the table and want to know what to actually run
**Journey:**

1. They find a stated recommendation.
2. It cites the rows it rests on, including the context cost, not only throughput.
3. Nothing in `config/` has changed underneath them, because this cycle measures and recommends.

**Tests to create:**

| Test | Input | Assertion | Informed by |
| --- | --- | --- | --- |
| `the writeup states a recommended slot count` | the writeup | it names one slot count as recommended for agent work | |
| `the recommendation cites both throughput and context cost` | the writeup | the recommendation references the per-slot window as well as a throughput figure | REPL: slots are bought with context here, so a throughput-only recommendation is incomplete |
| `the shipped configuration is unchanged by this cycle` | `config/llama-swap-kairic.yaml`, `config/opencode-kairic.jsonc` | the slot count and client context limit are what they were before the cycle | Nathan's call: measure and recommend, do not change |

**Done when:** the three tests above pass. All must be red when created.

**Depends on:** CUJ-04

**Beads:** `ubuntu-strix-ai-setup-8ld`

---

## CUJ-06: Nathan knows what the sweep will hold before it starts, and gets it back afterwards

**Actor:** Nathan, as the owner of the machine
**Trigger:** he authorises an hour-long sweep on his daily driver
**Journey:**

1. Nathan reads what the sweep will hold and for how long before starting it.
2. The sweep checks free memory before each arm and refuses rather than competing.
3. Every arm stops its own container, on success, on failure and on interrupt.
4. Afterwards one command shows the memory came back.

**Tests to create:**

| Test | Input | Assertion | Informed by |
| --- | --- | --- | --- |
| `the sweep stops its container on interrupt` | the harness killed mid-arm with SIGINT | no container from the sweep remains, and GTT returns to its pre-arm level | REPL: every probe this cycle trapped cleanup on EXIT/INT/TERM and each returned GTT to 2-3 GiB |
| `the sweep refuses to start an arm without headroom` | a headroom threshold set above what is free | it exits non-zero naming the shortfall, rather than launching | REPL: `lodestone-upstream` appeared on the machine twice mid-cycle without announcing itself |
| `the sweep reads GPU memory, not process memory` | the harness source | headroom comes from the amdgpu GTT node, not from RSS or podman stats | REPL: weights live in GTT; process-level tools reported a 47 GiB model as approximately nothing |

**Done when:** the three tests above pass. All must be red when created.

**Beads:** `ubuntu-strix-ai-setup-ejt`

---

## CUJ-07: A reader who distrusts the numbers can check them

**Actor:** a stranger who arrived from the benchmark and does not take claims on trust
**Trigger:** they want to know whether these figures mean anything
**Journey:**

1. They read every row's conditions, not just its value.
2. They find the harness that produced it, in the repository.
3. They can tell which figures are this machine's and which are quoted from elsewhere.

**Tests to create:**

| Test | Input | Assertion | Informed by |
| --- | --- | --- | --- |
| `every row names slot count, spec type, context, cache-ram and workload` | the results record | no row is missing any of the mandatory columns | REPL: acceptance ranges 46-76% on workload alone, so a row without its workload is unreadable |
| `the record distinguishes this machine's figures from quoted ones` | the results record | rows measured here and rows quoted from elsewhere are separable by a recorded marker, and quoted rows name their source | `bench/media-timings.tsv` carries this in a free-text notes column that `m08-timings.bats` greps for "this box" against "published"/"reference"; a dedicated column would be firmer |
| `the harness that produced the record is in the repository and runnable` | the results record and the tree | the harness path each row names exists and is executable | |

**Done when:** the three tests above pass. All must be red when created.

**Beads:** `ubuntu-strix-ai-setup-h9u`

---

<!--
Checks before finishing.

  Every actor-outcome pair in spec.md has a CUJ: seven pairs, seven CUJs.
  Every CUJ has a test table with real inputs and single observable assertions.
  Every "Done when" names tests and nothing else.
  Dependencies are sparse: CUJ-02 on CUJ-01, CUJ-05 on CUJ-04.

  Deliberate: the tests assert properties of the harness and the record, not the
  sweep's values. Pinning a throughput number in a test would make the suite
  fail on any other machine, which is the defect the previous cycle deleted a
  whole file for. CUJ-03's acceptance test is the one exception and it is
  defensible: 76.2% is a model property under fixed conditions, not a property
  of this box's clock speed.
-->
