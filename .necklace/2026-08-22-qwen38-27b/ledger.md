# Ledger — Qwen3.8-27B on Strix Halo

Cycle 3. The machine, the measurement discipline and the existing roster come from
`.necklace/2026-08-19-local-claude-suite/`; nothing here re-derives them.

## 2026-08-22 — Why this model gets its own cycle

Nathan asked for it by name. The interesting part is not the model, it is that
`julianmb/q38rocm` publishes a quantisation and engine built specifically for
gfx1151 and claims numbers that would beat the current roster.

Their published figures, all on this silicon:

    stock Q4_K_M                     12.27 tok/s
    ROCmFP4-FAST unassisted          14.02 tok/s
    ROCmFP4-FAST + MTP speculation   30.56 - 36.04 tok/s

### The claim that has to be tested

A dense 27B streams **all** its weights per token. The roster's current daily
driver, Qwen3.6-35B-A3B, is a MoE that streams roughly 3 B active and measures
**59.6 tok/s** on this box. So on arithmetic alone a dense 27B should lose
badly, and their own stock baseline of 12.27 agrees.

Everything therefore rests on MTP speculative decoding. If it is real here, a
27B dense model reaches 36 tok/s and becomes a genuine roster candidate. If it
is not, this is a slower model than the one already installed.

### MTP is unfinished business

Cycle 1 benchmarked Beinsezii's 122B HALO quant, which carries an MTP head, and
recorded it as losing to the homogeneous quant — 19.81 against 26.36 tok/s. That
comparison was made with `llama-bench`, which never speculates, so the head was
2.5 B of dead weight costing bandwidth and contributing nothing. I flagged it as
unsettled and moved on. This cycle is the chance to settle whether MTP is worth
anything on this hardware, using a model whose whole pitch depends on it.

### Two paths, both wanted

Nathan asked for the apples-to-apples number **and** the fork.

  1. **Stock Q4_K_M on b10502 Vulkan** — the same prebuilt binary behind every
     row in `bench/results.md`. Its value is comparability: it slots straight
     into the existing table with no caveats.
  2. **ROCmFP4-FAST on the forked engine** — a custom 4.26 bpw layout that stock
     llama.cpp cannot load at all, requiring a source build pinned to commit
     `0fc9568e07ccc8553010864cb8db1957e629cbfa`.

Path 2 must be measured twice, with speculation off and on, or it does not
answer anything: the quant and the speculation are separate claims and their
published numbers separate them (14.02 against 36.04).

### Build dependencies

`cmake`, `glslc`, `libvulkan-dev` and `spirv-headers` were missing. Nathan
installed them; `build-essential`, `git` and `mesa-vulkan-drivers` were already
present. That was the only privileged step this cycle needs.

### One number of theirs worth holding lightly

Their bandwidth model assumes ~190-200 GB/s sustained read. Cycle 1 measured
**~80 GB/s from the CPU side** and never established the GPU's ceiling directly.
Their figure is self-consistent with their own results, so it is probably right
for the GPU, but it is their measurement on their machine and this cycle should
not lean on it.

## 2026-08-22 — The fork's build script cannot build for this machine (probe 1)

`./build_engine.sh --static` fails at configure:

    CMake Error at CMakeDetermineHIPCompiler.cmake:197
      Failed to find ROCm root directory.
    Call Stack: ggml/src/ggml-hip/CMakeLists.txt:43 (enable_language)

`-DGGML_HIP=ON` is hardcoded at `build_engine.sh:143` and there is no flag to
turn it off. The `--rocm-only|--no-vulkan` switch does the opposite of what a
Vulkan-only machine needs: it disables **Vulkan** and keeps HIP.

So the project requires a full ROCm toolchain to build, on a machine where its
own headline feature is "Mesa RADV Wave64 Cooperative Matrix" and where Vulkan
is the backend cycle 1 measured as faster for decode. Building without ROCm is
a supported configuration in substance and an unsupported one in their script.

Worked around by invoking cmake directly with the same flag set minus HIP.

### Containerised, at Nathan's suggestion

`harness/Containerfile.rocmfpx` pins the engine at commit
`0fc9568e07ccc8553010864cb8db1957e629cbfa` — verified as the actual checkout
before writing it down, since the outer project's HEAD is a different commit
(`70b6689`) and confusing the two would pin the wrong thing.

Two deliberate departures from their build:

  - **`GGML_HIP=OFF`**, per above.
  - **`GGML_NATIVE=OFF`**, where theirs is ON. Native bakes the build host's CPU
    features into the binary, which is right for a tuned local build and wrong
    for an image meant to be reproducible. This costs some CPU-side performance
    and buys a benchmark that means the same thing on another machine. The
    numbers this cycle produces are GPU-bound anyway.

There is also a prebuilt tarball in their releases with a published SHA. Not
used: the engine source is a third repository (`charlie12345/ROCmFPX`), and
building from source we can pin is cheaper to trust than a binary we cannot
inspect.

### Correction: the build is tuned for this machine, not portable

I set `GGML_NATIVE=OFF` and dropped `GGML_AVX512`, reasoning that an image
should reproduce elsewhere. Nathan: this **is** a tuned build for this machine.

He is right and the reasoning was imported from a different problem. The
container's job here is to pin the engine commit and its build dependencies so
the build is repeatable — not to make the binary runnable on other silicon.
Portability was a goal nobody set, and paying CPU performance for it on a
performance investigation is backwards.

Both restored to upstream's values: `GGML_NATIVE=ON`, `GGML_AVX512=ON`. Zen 5
has AVX-512, so dropping it was a real loss and not a theoretical one.

## 2026-08-22 — My container reported CPU numbers as if they were GPU numbers (probe 2)

First ROCmFP4 run came back at **2.94 tg128** against a published 14.02, with
`backend: CPU` in the table. I was one step from writing that down as "the
fork's quant does not work on Vulkan".

Nathan: "This is custom built for my literal machine so you are definitely the
one who is wrong." Correct. A control run settled it in one command — stock
Q4_K_M through the same container also reported **CPU**, so the fault was mine
and not the quant's.

    /usr/share/vulkan/icd.d/    NO ICD DIRECTORY
    libvulkan.so.1              present
    /dev/dri/renderD128         present

`libvulkan-dev` is build-time headers. **`mesa-vulkan-drivers` is the RADV ICD
the loader needs at run time**, and I never installed it in the image. Device
nodes present, loader present, no driver behind it — so llama-bench enumerated
nothing and fell back to CPU.

That failure mode is worse than an error: it produces a plausible-looking table
with a `backend` column nobody reads carefully, four times slow, and invites
exactly the wrong conclusion about someone else's work.

After adding `mesa-vulkan-drivers libvulkan1`:

    ggml_vulkan: 0 = Radeon 8060S Graphics (RADV GFX1151) (radv) | uma: 1 ...

### The real numbers

    stock Q4_K_M    b10502 Vulkan  15.65 GiB  192.0 pp512  12.23 tg128
    stock Q4_K_M    fork, Vulkan   15.65 GiB  162.8 pp128  11.24 tg32
    ROCmFP4-FAST    fork, Vulkan   13.55 GiB  202.1 pp512  11.91 tg128

    published: stock 12.27, ROCmFP4 unassisted 14.02

Our stock baseline reproduces theirs almost exactly — **12.23 against 12.27**,
0.3% apart. That is the strongest evidence available that the measurement setup
is now sound.

ROCmFP4 unassisted comes in at **11.91** against their 14.02. It wins clearly on
prefill (202 against 192) and is marginally *slower* on decode, on 13.4% less
data. Their 14.02 was measured on a HIP build; this is Vulkan. The quant loads
and runs GPU-accelerated on Vulkan, which their documentation does not promise.

**Speculation is still untested**, and it remains the whole case: 11.91 is worse
than the 59.6 tok/s MoE already serving `fast`.

## 2026-08-22 — ROCm in a container, which is where it belonged (probe 3)

I spent several rounds leading Nathan toward installing ROCm on the host. It went
badly and he stopped it:

  - Distro ROCm 7.1 (105 packages, 2.77 GB) gave a working **runtime** — rocminfo
    enumerates gfx1151, rocBLAS ships `*_fallback_gfx1151.hsaco` — but no working
    HIP **compiler**. Ubuntu's clang-21 has no ROCm device-math implementation:
    308 errors on `fabsf`, `fmaxf`, `powf`, `max`, `min`.
  - AMD publishes no suite for 26.04 (`repo.radeon.com/.../dists/` has jammy and
    noble only), so their noble packages collide with the distro's: Ubuntu numbers
    `rocm-cmake` 7.1.1 against AMD's 0.14.0, and 24 dependencies fail at once.
  - Resolving that needs a priority-1001 apt pin to force downgrades across the
    overlapping set, plus hand-copying noble `libxml2`/`libicu` `.so` files into
    `/opt/rocm-7.2.2/lib` because ROCm's `lld` links against sonames 26.04 does
    not ship.

Nathan: "Ok you are clearly leading me down a path that's about to mess up my
machine... What exactly is this for anyways? Inference or compilation? Because if
it's just compiling... we can JUST USE PODMAN."

That is the right question and the right answer. ROCm is needed for both, but
**both can live in a container**, and cycle 2 already proved rootless podman
reaches gfx1151 unprivileged. On a noble base every problem above evaporates:
AMD's repo is a first-class target there, so no pin, no shims, no collision.

    ggml_rocm_init: found 1 ROCm devices (Total VRAM: 112640 MiB)
    Device 0: Radeon 8060S Graphics, gfx1151 (0x1151), VMM: no, Wave Size: 32

The host kept nothing. Everything Nathan ran is in `docs/privileged-steps.md`
with rollbacks, including the pin and the `.so` shims marked as proposed and
never run.

I had containerised the Vulkan build an hour earlier and still did not see it.
The requirement was never "install ROCm"; it was "a process with ROCm must touch
the GPU", which this repo had already solved twice.

### Two container bugs, both silent until run time

**No RADV ICD.** `libvulkan-dev` is build headers; `mesa-vulkan-drivers` is the
driver. Without it the Vulkan image enumerated nothing and llama-bench reported
`backend: CPU` at 2.94 tg — a plausible table that nearly became a published
claim about someone else's quantisation.

**Shared libraries copied without their symlinks.** `find -type f -exec cp`
took `libllama-common.so.0.0.244` and left `libllama-common.so.0`, which is what
the loader resolves. `cp -a` fixes it. The build reported success both times.

### The numbers

    stock Q4_K_M    b10502 Vulkan   15.65 GiB   192.0 pp512   12.23 tg128
    stock Q4_K_M    fork Vulkan     15.65 GiB   162.8 pp128   11.24 tg32
    ROCmFP4-FAST    fork Vulkan     13.55 GiB   202.1 pp512   11.91 tg128
    ROCmFP4-FAST    fork ROCm/HIP   13.55 GiB   242.7 pp512   12.80 tg128

    published: stock 12.27, ROCmFP4 unassisted 14.02, +MTP 30.56-36.04

HIP beats Vulkan on this quant: **+20.1% prefill** (242.7 vs 202.1) and **+7.5%
decode** (12.80 vs 11.91). That is close to cycle 1's cited expectation of ROCm
winning prefill by roughly a fifth — now measured here rather than quoted.

Decode at 12.80 is still short of their 14.02 and far short of the 59.6 tok/s MoE
already serving `fast`. **MTP speculation remains the whole case, and is still
untested.**

## 2026-08-22 — MTP speculation is real: +78% decode (probe 4)

`llama-bench` never speculates, so this needed `llama-server` and real requests.
The fork's own `run_server.sh` translates its `MTP=1` default into:

    --spec-type draft-mtp --spec-draft-n-max 4 --spec-draft-p-min 0.0
    --spec-mtp-strict-qwen        (when STRICT_MTP=1)

The MTP head lives inside the ROCmFP4 GGUF, so there is no separate draft model.

Matched A/B — identical container, model, flags, prompt and deterministic
sampling (temperature 0, top_p 1, top_k 0), three runs each. Token counts were
identical within each arm, which confirms the determinism:

    speculation OFF   365 tok   12.7, 12.7, 12.7 tok/s
    MTP + strict      348 tok   22.8, 22.5, 22.7 tok/s

**+78.0%.** That settles the question cycle 1 left open when the 122B HALO quant
was benchmarked with its MTP head switched off: on this hardware, MTP
speculation is worth a large, repeatable gain, and any benchmark that cannot
exercise it understates an MTP-carrying model badly.

### Against their published figures

    published stock                12.27      measured 12.23 (b10502 Vulkan)
    published ROCmFP4 unassisted   14.02      measured 12.70 (HIP, server)
    published ROCmFP4 + MTP     30.56-36.04   measured 22.7  (HIP, server)

The stock baseline reproduces to 0.3%, so the harness is sound. The speculation
arm reaches 63-74% of their claimed range. Their number is an aggregate over a
164-task coding suite at 262,144 context with an 8 GiB prompt cache and 32
context checkpoints; this is one prompt at 32,768 with no cache. Acceptance rate
drives speculative throughput and varies by workload, so the gap is plausible
without either measurement being wrong — but it is a gap, and it is theirs to
explain rather than mine to close.

### A failure that told me exactly how to fix it

    E srv load_model: Qwen strict MTP requires a single server slot/sequence;
      restart with -np 1 or use --no-spec-mtp-strict-qwen

Named the constraint, the flag, and the alternative. Worth contrasting with the
two silent container failures earlier today, which reported success and produced
wrong numbers.

### Still to do

Kairic Edge is the other IU4 release and needs a *different* fork
(`ciru-ai/ROCmFPX`, branch `kairic-edge-qwen38-27b-v1.1`) plus a patched
Composable Kernel, and claims 47.73 aggregate. Same containerised approach
applies. 122B is shelved at Nathan's direction.

## Kairic Edge — reading the runner before trusting the number

Their README says `git checkout kairic-edge-qwen38-27b-v1.1`. That ref does not
resolve. The real branches carry a `release/` prefix:
`release/kairic-edge-qwen38-27b-v1` (`e97b3246`) and
`release/kairic-edge-qwen38-27b-v1.1` (`e1da26bb`). Built from the latter.

All four artifacts verified. The card's published SHA-256 values match
HuggingFace's own LFS object ids exactly, and the downloaded sidecars match
both:

| artifact | bytes | sha256 verified |
|---|---:|---|
| `Qwen3.8-27B-IU4-Kairic-Edge.gguf` | 16,617,792,672 | `360caf73…` |
| `Qwen3.8-27B-Kairic-IU4-FFN.pfs` | 8,576,856,064 | `adcbb90a…` OK |
| `Qwen3.8-27B-Kairic-IU4-GDN.pfs` | 2,019,569,664 | `82f93131…` OK |
| `Qwen3.8-27B-Kairic-IU4-GDN-Output.pfs` | 756,953,088 | `3b07e7b1…` OK |

### Their 47.73 is a speculation number, not a raw decode number

`scripts/run-kairic-edge-gfx1151.sh` passes `--spec-type draft-mtp` by default.
So the aggregate figure already includes MTP. Compared against our own MTP arm
(22.7 tok/s on ROCmFP4), not the 12.7 unspeculated baseline. Comparing it to
12.7 would credit Kairic with speculation we already measured separately.

### The fast path buys speed by refusing work

The runner defaults `KAIRIC_EDGE_COMPATIBILITY_MODE=0`, which sets
`LLAMA_TARGET_GREEDY_ARGMAX_FASTPATH=1`. The GPU argmax omits the host logits
array entirely, so anything that needs logits cannot be served. To their
credit it throws instead of silently degrading (`server-task.cpp:629-692`), but
the accepted request shape is narrow: temperature 0, top_k 0 or 1, top_p 1,
min_p 0, no penalties, single completion, and none of

- grammar or grammar triggers
- logit bias
- `n_probs` / post-sampling probabilities
- LoRA
- a reasoning budget

No grammar is the one that bites. opencode and goose both lean on
JSON-schema-constrained output for tool calls, so the configuration that
produces the headline number cannot serve the agent suite this repo exists to
run. `KAIRIC_EDGE_COMPATIBILITY_MODE=1` lifts the restriction, which makes the
compatibility arm the number that decides whether this model is usable here.
Measuring both.

### Correction to the paragraph above

I wrote that no-grammar meant the agent suite could not run. That was reasoning
from the source without testing it, and it was too strong. Measured behaviour:

| capability | fastpath (their default) | compatibility mode | ROCmFP4 |
|---|---|---|---|
| plain greedy completion | yes | yes | yes |
| tool calls (`tools:`) | **400** | yes | yes |
| temperature > 0 | **400** | yes | yes |
| raw GBNF `grammar` | **400** | yes | yes |
| `response_format: json_object` | **400** | yes | yes |
| `response_format: json_schema` | **400** | **400** | yes |
| logprobs | **400** | yes | yes |

Compatibility mode serves everything an agent needs except one path. The
restriction belongs to the fast path, not to the fork.

The `json_schema` failure is separate and survives compatibility mode. It
returns `Failed to initialize samplers: std::exception` (400), not the argmax
message, so it is a distinct fault in this branch's JSON-schema-to-GBNF path.
Base ROCmFPX serves the same request, so it arrived with Kairic. Workaround:
`json_object` plus raw GBNF both work, and opencode and goose reach tool calls
through the `tools:` path, which is fine. Retest if a later release changes the
sampler init; nothing to do until then.

### Prompt Forge really did route

Worth confirming before trusting any of it, because Prompt Forge is documented
to fail closed to the plain GGUF, which would look like a slow result rather
than an error. It routed:

    promptforge_init      wmma=v_wmma_i32_16x16x16_iu4  device_bytes=8576856064
    promptforge_gdn_init  qkvz_iu4_hadamard  layers=48
    promptforge_gdn_output_init  output_iu4  layers=48
    Kairic Edge: enabled

The native IU4 instruction is genuinely in the loop. So is MTP.

Note `decode_rows:[2,3,4,5]`. The IU4 lane engages on 2-to-5-row shapes, which
are MTP verification batches, and the card states plainly that M1 decode is not
native IU4. Single-token decode therefore picks up IU4 only indirectly, through
whatever MTP verification accepts. That is the mechanism behind a large prefill
gain and a small decode gain, and it is consistent with what we measured.

### Results — one driver, three arms, same prompts

`repl/kairic-bench.sh`. Three prompts (systems prose, a red-black tree in C,
a hardware comparison), 384 tokens each, greedy, one warmup discarded, MTP on
in every arm. The earlier 22.7 tok/s ROCmFP4 figure was taken by hand on
different prompts, so it was re-measured here rather than quoted.

| arm | tok/s (3 prompts) | mean | vs ROCmFP4 | usable by agents |
|---|---|---:|---:|---|
| Kairic, fast path | 17.99 / 23.53 / 17.36 | **19.62** | +25.7% | **no** |
| Kairic, compatibility | 15.33 / 19.49 / 15.28 | **16.70** | +7.0% | yes |
| ROCmFP4-FAST | 14.88 / 17.45 / 14.50 | **15.61** | — | yes |

The fast path is worth 14.9% over compatibility mode, and it costs tool calls,
sampling, grammar and logprobs to get it.

### On the 47.73

The card's headline is an aggregate over a 164-task coding suite at 262,144
context with an 8 GiB prompt cache, `--cache-idle-slots` and `-ctxcp 32`, on a
workload full of repeated prefixes where that cache cuts prompt time by
98.39–99.87%. We measured 19.62 at 32,768 context, no cache allocation, three
unrelated prompts. Those are different questions and the gap is mostly the
question, not the answer.

Their own single-generation rows are the fair comparator, and we still land
under them: forced-512 prose 30.87, natural prose 34.88 against our 19.62, so
63.6% of the closest published slice. Unexplained. Candidates we did not
separate: the prompt-cache allocation may help even without prefix reuse, 262K
context may change the KV layout in their favour, and their prose slice content
is not published so it may simply decode faster than a red-black tree.

Not chased further, because it does not change the decision. Every arm here ran
under one driver on one machine, and against the alternative we actually have,
Kairic gives +7.0% in the only configuration that can serve a tool call.

## Correction: the Kairic numbers above are wrong, and here is why

The 19.62 / 16.70 / 15.61 table was a bad measurement presented as a verdict.
Three defects, in descending order of how much damage they did:

**1. Wrong workload.** Three prose-and-C prompts, then compared against an
aggregate over a coding suite. Speed on this model is dominated by MTP draft
acceptance, which is a property of how predictable the output is. Measured
here: HumanEval accepts 76.2% of drafts, discursive prose accepts 46-47%. The
card's own table said this plainly — prose slice 34.88 against HumanEval slice
48.78 — and I quoted that table without registering what it meant.

**2. Unmatched arms.** Kairic got `--spec-draft-backend-sampling` and
`--spec-draft-p-min 0.0`; ROCmFP4 got neither, so its drafts were being
rejected. Kairic also ran `--reasoning off` via its runner while ROCmFP4 did
not, so ROCmFP4 was generating 3950 tokens of chain-of-thought against Kairic's
1621 for the same ten tasks. The tell was there and I missed it: the new
ROCmFP4 figure (15.61) came in *below* my own earlier hand measurement of the
same model (22.7), which should have stopped the writeup cold.

**3. No acceptance instrumentation.** A speculative-decoding number without an
acceptance rate does not say whether speculation happened. It is the first
thing to record, not an afterthought.

### Re-measured: HumanEval 0-9, against the card's published hot slice

Driven through the vendor's own `scripts/run-kairic-edge-gfx1151.sh` so flag
transcription cannot be the explanation, at its release defaults (262144
context, `--cache-ram 8192`, `-ctxcp 32`, `--cache-idle-slots`). ROCmFP4 given
the identical speculation and reasoning settings. Script:
`repl/kairic-humaneval.sh`.

| arm | cold | hot | tokens | draft accept |
|---|---:|---:|---:|---:|
| Kairic, fast path | 40.03 | **56.72** | 1621 | 76.2% |
| Kairic, compatibility mode | 28.41 | **41.89** | 1621 | 76.2% |
| ROCmFP4-FAST, matched | 24.35 | **22.21** | 1612 | 95.7% |

Card's published HumanEval 0-9 hot slice: 48.78. We measured 56.72. The claim
is not merely reproducible on this machine, it is beaten.

    Kairic fast path vs ROCmFP4    2.55x   (+155%)
    Kairic compatibility vs ROCmFP4 1.89x   (+88.6%)
    fast path vs compatibility      1.35x   (+35.4%)

Compatibility mode is the one that serves tool calls, and it is still nearly
twice ROCmFP4. The earlier finding that compatibility mode costs 14.9% was also
wrong; on this workload it costs 26%, and it is worth paying.

### The mechanism is verification speed, not acceptance

ROCmFP4 accepts 95.7% of its drafts and is still 2.5x slower. Kairic accepts
fewer and wins anyway, which means the gain is in how fast it verifies a draft
batch. That is exactly the IU4 lane, which `promptforge_init` reports as
covering `decode_rows:[2,3,4,5]` — MTP verification shapes. The architecture
claim and the measurement agree.

### What did not explain anything

The release configuration. Prose re-run under the full vendor config gives
16.77 / 20.97 / 16.53 against the original 15.33 / 19.49 / 15.28. The 262K
context and 8 GiB prompt cache are worth almost nothing on fresh single
generations with no shared prefix. It was the workload the whole time.

### Still open

On prose we land near 17-21 tok/s against the card's natural-prose slice of
34.88, so roughly half. Their prose slice content is not published and ours is
adversarially unpredictable, which plausibly covers it, but this is not settled
and should not be written up as settled. It does not affect the coding result,
which was measured against a defined task set and exceeded.
