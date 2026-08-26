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

## Operational notes the correction above skipped

Two failures cost real time and neither is obvious from the outside.

**The ROCmFP4 image entrypoint is `llama-bench`, not `llama-server`.** Passing
server flags to it prints a usage block and exits, and under `podman run -d
--rm` the container is gone before you can read the log, so the arm just
reports "container died". Any `podman run` against `localhost/rocmfpx-hip` that
wants the server must pass `--entrypoint /engine/llama-server`. To see why a
`--rm -d` container died at all, re-run it in the foreground without `-d`;
otherwise the evidence deletes itself.

**`LLAMA_MTP_CPU_ARGMAX_FASTPATH=1` aborts the server at startup unless
`--spec-draft-backend-sampling` and `--spec-draft-p-min 0.0` are both set.**
The abort is a `ggml_abort` with a backtrace, not a friendly message:

    speculative.cpp:1003: MTP CPU argmax fast path requires backend sampling and p_min=0

The vendor runner sets both, so this only bites when hand-assembling flags —
which is the argument for driving their `run-kairic-edge-gfx1151.sh` rather
than transcribing it.

## What is verified and what is not

**Verified on this machine:** decode throughput, draft acceptance, that Prompt
Forge routes rather than falling back, which request shapes each mode serves,
and artifact integrity by SHA-256.

**Not verified:** output correctness. The HumanEval prompts were used as a
throughput workload only. Completions were never executed against the test
suite, so the card's 158/164 Base and 152/164 Plus are unchecked here, as is
any claim that IU4 preserves quality against the stock Q4_K_M. Nothing measured
in this cycle would detect a model that generates fluent wrong code quickly.
Settling it means executing model-generated code, which belongs in a throwaway
container with no network and no host mounts, not on the daily driver.

**Not compared:** stock Q4_K_M under MTP with matched settings. It lost on
llama-bench without speculation (12.23 tg128), and MTP is unlikely to reorder a
gap this size, but "unlikely" is not "measured".

## Kairic is not wired into anything yet

`config/llama-swap.yaml` still points every role at
`~/.local/opt/llama.cpp-vulkan/llama-b10502/llama-server`, and the Makefile has
no Kairic target. The engine exists only as `localhost/kairic:v1.1` plus the
repl scripts. Using it day to day needs a launch path; nothing here creates one.

## Serving configuration: Kairic at full context, with compaction alongside

Three artifacts: `config/llama-swap-kairic.yaml`,
`systemd/llama-swap-kairic.service`, `config/opencode-kairic.json`, plus
`make kairic-install / kairic-up / kairic-down`.

### Context is 262144 and that is the model's real ceiling

`qwen35.context_length` in the GGUF header is 262144 for both the 27B and the
4B, and the running server reports `n_ctx: 262144` through
`/upstream/code/props`. Nothing is being extended with rope tricks.

### Why compaction needs its own model, and which knob actually selects it

`small_model` does not drive compaction. opencode resolves the compaction model
at `packages/opencode/src/session/compaction.ts:358-361`:

    const agent = yield* agents.get("compaction")
    const model = agent.model ? getModel(agent.model...) : getModel(userMessage.model...)

So it uses the *main* model unless the built-in `compaction` agent has one set.
The knob is `agent.compaction.model`, confirmed against the published schema,
which also exposes `title` and `summary` agents. `small_model` is set too, but
it is the weaker guarantee and would not have worked on its own.

`limit.context: 262144` on the model is what opencode measures against to
decide when to compact, so it has to be the truth or compaction fires at the
wrong time — too early wastes the window, too late overflows it.

### Choosing the compaction model

`empero-ai/Qwen3.8-4B-Distill-GGUF` at Q8_0, 4.29 GiB on disk. Same `qwen35`
hybrid architecture as the 27B, so its 262144 window is cheap for the same
reason the 27B's is: mostly Gated DeltaNet blocks with constant state.

Q8_0 on a 4B in preference to Q4 on a 9B. A compaction summary is written once
and then silently conditions every later turn, so an error there is both
expensive and invisible. Spend the bits where the mistakes cannot be seen.

Its context matches `code` exactly. opencode hands compaction a transcript
nearly as large as the main window, so a smaller window here would fail exactly
when compaction became necessary.

Measured at 262144: 14 GiB resident, 1025 tok/s prefill, 34.0 tok/s generation.
Prefill is what matters for compaction, since the job is mostly reading — and
1025 tok/s beats the 27B's own prefill, so the small model is the faster
compactor as well as the cheaper one. `-ctk q8_0 -ctv q8_0` drops it to 11 GiB
for about 3% throughput if the memory is ever needed.

### Measured footprint, end to end

    baseline idle                    13 GiB used
    code + compact both resident     74 GiB used, 48 GiB free
    after `make kairic-down`         13 GiB used, 109 GiB free

61 GiB for the pair, which matches the 46 + 14 measured separately. **48 GiB
free is tighter than it looks** — a 234-job C++ build on this machine took
42.5 GiB, and 74 + 42.5 is 116 of 122. It fits, with little to spare. Levers,
in order of preference: `CACHE_RAM=8192` down to 4096 frees 4 GiB, q8_0 KV on
`compact` frees 3 GiB, then the 2B distill instead of the 4B frees another 2.

### Two contracts cannot coexist, so the config makes it impossible

`config/llama-swap.yaml` carries `deep` at 69.1 GiB. 69 + 61 does not fit. The
Kairic roles therefore live in a *separate* config file rather than as extra
roles in that one, so the overcommit cannot be written down, instead of being
prevented by group semantics I would have had to get exactly right. `make
kairic-up` additionally refuses to start if `llama-swap` is already active, and
if fewer than 70 GiB are free.

`swap: false` on the group keeps both loaded; verified by loading `code`, then
`compact`, then confirming `code` still answered.

`ExecStopPost` reaps both containers, because llama-swap spawns podman and a
killed llama-swap can otherwise leave 60 GiB parented to conmon. `make
kairic-down` prints free memory afterwards so "stopped" is demonstrated.

### Verified working, not just written

    n_ctx reported                  262144
    tool call through the contract  {"name":"get_weather","arguments":{"city":"Chicago"}}
    compact loaded without evicting code   yes
    teardown returned all memory           109 GiB

`KAIRIC_EDGE_COMPATIBILITY_MODE=1` is load-bearing in that config and is
commented as such. At 0 the tool call above returns 400.

## Can the 27B and the 4B share a KV cache? No, and not for a fixable reason

They are the same architecture family, not the same model:

| | 27B Kairic | 4B distill |
|---|---:|---:|
| blocks | 65 | 33 |
| embedding | 5120 | 2560 |
| q heads / kv heads | 24 / 4 | 16 / 4 |

A KV entry is the K and V projection that *a specific set of weights* produced
for a token at a given layer. Layer 12 of the 4B holds different weights than
layer 12 of the 27B, so its keys occupy a different space; here the tensor
shapes do not even match, so it cannot be attempted. Identical geometry would
not rescue it either — different weights make the cached projections
meaningless. A distill imitates outputs, not internal representations.

### The prompt cache does not rescue it either, even on one model

The interesting version of the question is whether compaction could reuse the
transcript the 27B has already prefilled. It cannot, and the reason is in
opencode rather than in llama.cpp. `compaction.ts:379` builds its request as:

    const conversation = msgs.map(serialize).filter(Boolean).join("\n\n")

The head is flattened into a single text blob, wrapped in `buildPrompt`, and
sent as one user message with `system: []`. It does not replay the original
message array. So the token sequence diverges from the live conversation at
position zero, and llama.cpp's prompt cache — which matches prefixes — misses
completely. Running compaction on `code` itself would re-read everything too.

### Which is the argument for the separate model, measured

Since the transcript is re-prefilled from scratch regardless, the only question
is which model reads it fastest. Same 19,625-token payload, same machine:

    27B Kairic   86.0 s    228 tok/s
    4B Q8_0      19.1 s   1025 tok/s   4.49x

Extrapolated to a 200k-token compaction: roughly 15 minutes on the 27B against
3.3 minutes on the 4B. That is what the 14 GiB buys. If the memory is ever
worth more than the eleven minutes, delete `agent.compaction.model` from
`config/opencode-kairic.json` and compaction falls back to `code`
automatically — the fallback is the documented behaviour at
`compaction.ts:359-361`, not an accident.

## Scorecard: did we reach the published numbers?

The card's most directly comparable figure is not in any of its results tables.
It is one sentence in the "Recommended launch" prose:

> Compatibility measured 41.87 versus 46.37 generated tokens/s on that short
> coding subset, a 9.70% reduction

That is HumanEval 0-9 in compatibility mode — the same ten tasks and the same
mode measured here. It went unnoticed on the first read because attention was
on the 47.73 headline.

| claim | card | ours | verdict |
|---|---:|---:|---|
| HumanEval 0-9, compatibility | 41.87 | **41.89** | matched, 0.048% |
| HumanEval 0-9, fast path (gate) | 46.37 | **56.72** | exceeded +22.3% |
| HumanEval 0-9, hot slice | 48.78 | **56.72** | exceeded +16.3% |
| Natural prose slice | 34.88 | 16.8-21.0 | **not reached, ~half** |
| Forced-512 prose slice | 30.87 | 16.5-21.0 | **not reached** |
| Aggregate PP | 358.45 | 228 | not comparable, see below |
| 164-task aggregate TG | 47.73 | — | **never tested** (we ran 10 tasks) |
| Peak TG | 106.68 | — | never tested |
| HumanEval Base / Plus | 158 / 152 | — | never scored |
| IU4 instruction harness | 104.66 TOPS | — | never tested |
| Prompt cache reduction | 98.39-99.87% | — | never tested |
| Served verification A/B | 48.73 -> 52.57 | — | never tested |

Matching a published throughput figure to five hundredths of a token per second
on an independent build of the source is about as strong a confirmation as this
kind of measurement offers. It also retires any remaining doubt about the
harness: the container, the CK patch, the sidecar wiring and the runner are all
doing what the publisher's own machine did.

### The anomaly worth keeping visible

Compatibility mode matches exactly while the fast path comes in 16-22% *above*
every figure they publish for it. Their fast-to-compatibility ratio is 1.107;
ours is 1.354. Both cannot be right about the same fast path.

Since the compatibility number reproduces to within 0.05%, the setup is not in
question — whatever differs is on the fast-path side. The likeliest candidate is
that our "hot" second pass fed the prompt cache in a way their release gate did
not, which would inflate our fast number rather than deflate theirs. Not
resolved, and not worth resolving: the number that governs daily use is the
compatibility one, and that one is confirmed.

### Aggregate PP is not comparable and should not be read as a miss

Their 358.45 is a suite aggregate, and their own PP sweep ranges 325-529 tok/s
across 96-to-512-row shapes. Our 228 came from a single 19,625-token prompt,
which is a different regime entirely. Nothing here contradicts their figure; the
two numbers simply do not measure the same thing.

### Answer

On the workload the card publishes for the mode this machine will actually run,
yes — reproduced to 0.05%, and beaten in fast mode. The 47.73 headline remains
untested, because that is 164 tasks and we ran ten. Prose remains at roughly
half the published slice and is still unexplained.

## opencode reads one path, and it is not the one an env var points at

The first instructions said to export `OPENCODE_CONFIG`. That is wrong for the
way this gets used. The desktop app is launched from the desktop, not from a
shell, so it never sees anything exported in `.bashrc` — it came up showing
OpenCode's own free hosted models with no `contract` provider at all.

opencode reads `~/.config/opencode/opencode.jsonc`, and the app creates that
file itself on first launch (containing only `$schema`). Note the extension:
`.jsonc`, not `.json`.

The repo copy is now `config/opencode-kairic.jsonc` and
`~/.config/opencode/opencode.jsonc` is a symlink to it, so the configuration
stays version-controlled while sitting at the only path that works for both the
CLI and the GUI. `make kairic-install` creates the symlink.

Verified end to end rather than by inspection:

    opencode models              -> contract/code, contract/compact
    opencode run --model contract/code     -> "KAIRIC OK"
    opencode run --model contract/compact  -> "COMPACT OK"
    memory with both loaded      79 GiB used, 43 GiB free

Installed version is opencode 1.18.23, not the 1.18.19 pinned in
`harness/Containerfile.opencode` from the first cycle.

## The memory ceiling I quoted was wrong

I told Nathan the worst case was bounded at 81 GiB by construction: weights and
the full 262144 KV allocated up front, plus an 8 GiB prompt-cache cap. The
first half is right. The arithmetic was not.

Observed after ordinary use — a handful of opencode round trips, nothing
adversarial:

    at load                60 GiB (46 + 14)
    after a few requests   79 GiB used
    after more             91 GiB used, 31 GiB free

31 GiB free against a 42.5 GiB build is not the margin I described.

### Why it was invisible, and where to actually look

`podman stats` reported 4.8 GB for kairic-serve and 1.3 GB for compact-serve —
6 GB between them, while the system showed 91 GiB used. The weights and caches
live in **GTT**, which is GPU-visible memory, not process RSS. GTT read 71.3 GiB
at the same moment.

    watch: /sys/class/drm/card1/device/mem_info_gtt_used
    not:   podman stats, ps, or anything else RSS-based

This is the same class of mistake as measuring prose and calling it a coding
benchmark: the instrument was reporting something real, just not the thing.

### Response

`CACHE_RAM` lowered from the vendor's 8192 to 4096 in
`config/llama-swap-kairic.yaml`. This is a **partial mitigation, not a bound**,
and the earlier wording here calling it "the one knob that bounds the growth"
was wrong. Corrected accounting:

    baseline, no models        13 GiB used
    both models loaded         74 GiB used   -> 61 GiB of models
    observed peak              91 GiB used   -> +17 GiB of growth

The prompt cache can account for at most 8 of those 17 GiB, so roughly 9 GiB is
unattributed, and halving CACHE_RAM recovers at most 4. Candidates for the rest,
none of them bounded by `--cache-ram`: the 32 context checkpoints
(`-ctxcp 32`), which snapshot recurrent state for a 65-block hybrid; the MTP
draft context; and compute buffers sized by `-b 2048 / -ub 512` during large
prefills. Not isolated — measuring it means watching
`mem_info_gtt_used` while varying one flag at a time, which is a deliberate
experiment nobody has asked for.
Cost is prompt-cache hit rate on repeated prefixes. `-ctxcp 32` stays, because
the card states checkpoints are required for correct recurrent-state restore on
this hybrid model — dropping them trades memory for wrong answers.

The new ceiling is *projected*, not measured. The measured facts are 91 GiB at
8192, and that GTT is where to watch.

## opencode has no way to hide a model that compaction still uses

The compaction model appears in the desktop model picker as a selectable chat
model, which it should not be. The available mechanisms and what they do:

| approach | hides it | still usable by compaction |
|---|---|---|
| `status: "deprecated"` | yes | **no** — the model stops resolving |
| provider `blacklist` | yes | no, same reason |
| nothing | no | yes |

Tested: with `status: "deprecated"`, `opencode models` no longer lists
`contract/compact` and `opencode run --model contract/compact` fails with
`UnknownError`, while `contract/code` continues to work. Per-model config
carries no `hidden` field; `hidden` exists only on `AgentConfig`.

So it stays visible. Renaming it to something obviously internal is the whole
available remedy.

## The repetition loop was the sampler, and the sampler was my fault

Nathan ran opencode against `code` and it re-issued the identical shell command
for close to an hour. Not a model defect and nothing to do with Unsloth — the
Unsloth quants are the card's *comparison* arms and were never downloaded here.

The running server was configured like this:

    temperature 0.0   top_k 0   top_p 1.0
    repeat_penalty 1.0   presence_penalty 0.0

Pure greedy with every penalty disabled. Once decoding enters a repetition
attractor there is nothing to push it out, so the same tool call comes back
forever. Those are the vendor runner's defaults and they are correct for what
the runner is for — reproducible benchmarking, byte-identical output between
runs. They are wrong for agent work, and the card says so, giving Qwen's live
values for compatibility mode: temp 0.7, top_p 0.8, top_k 20, presence 1.5.

I wired the benchmark configuration straight into interactive use.

### Fix

`config/run-kairic-serve.sh` is the vendor runner with only the sampler line
changed, overridable by `KAIRIC_TEMP` / `KAIRIC_TOP_P` / `KAIRIC_TOP_K` /
`KAIRIC_PRESENCE_PENALTY`. Fixed at the server so it holds no matter what a
client sends. Verified in `/props`:

    temperature 0.7   top_p 0.8   top_k 20   min_p 0.0   presence_penalty 1.5

### A bash trap that hid the first attempt

The first patch put explanatory comments between continuation lines:

    --spec-draft-backend-sampling \
    # Qwen's recommended LIVE values ...
    --temp 0.7 ...

A backslash joins the next line, so the `#` commented out **the entire rest of
the command**. Every flag after `--spec-draft-backend-sampling` vanished,
including `--reasoning off`. `bash -n` passes, the server starts, and nothing
complains — sampling silently fell back to the GGUF's own generation config
(temp 1.0, top_p 0.95, min_p 0.05), which is close enough to plausible that it
does not look wrong. Only `podman top` showed the truncated argv.

Rule: never put a comment inside a line-continuation block. Verify a launcher by
reading the process's actual argv, not by reading the script.

### Live sampling costs nothing measurable here

Concern was that sampling would lower MTP draft acceptance and cost throughput,
since the published figures are all greedy. Same red-black-tree prompt:

    temp 0 greedy      19.49 tok/s   72.4% accept
    temp 0.7 + pp1.5   20.04 tok/s   73.9% accept

Within noise, no penalty. The benchmark numbers elsewhere in this ledger remain
greedy measurements and should stay labelled that way, but there is no
throughput argument for running an agent greedy.


## Correction: the 81 GiB ceiling was a constraint I invented

Nathan never asked for memory below any particular figure. He asked for a setup
that did not blow up his memory at max context. The measured peak was 91 GiB of
122, leaving 31 GiB free. That is not blowing up; it fit.

What went wrong is subtler than a bad estimate. I guessed a ceiling of 81 GiB,
measured 91, and then treated my own wrong guess as a specification to satisfy —
lowering `CACHE_RAM` below the vendor's documented 8192 to close a gap that only
existed relative to a number I had made up. The card measures that cache cutting
repeated-prefix prompt time by 98.39-99.87%, so the change traded a real,
published performance feature for imaginary safety.

Reverted to 8192.

The failure mode to watch for: an estimate that turns out wrong is a fact about
the estimate, not a defect in the system. Correct the estimate. Do not
re-engineer the system to make the old estimate true.

The one case where 91 GiB genuinely collides is a concurrent 42.5 GiB build:
91 + 42.5 exceeds 122. That is a scheduling decision for the day it comes up —
stop the contract, or lower the cache then — not a reason to degrade the default.

## LSP was off because the config omitted it

opencode reported "LSPs are disabled". Not a bug — the schema is explicit:

> Enable or configure LSP servers. Omit or set to false to disable, true to
> enable built-ins, or an object to enable built-ins with overrides.

Omitting the key disables them. `config/opencode-kairic.jsonc` omitted it, so
they were off. Added `"lsp": true`.

Verified rather than assumed: `opencode debug config` reports `lsp: True`, and
`opencode debug lsp diagnostics` on a deliberately broken Python file returned a
real Pyright diagnostic. opencode installs and manages the servers itself — none
of pyright, gopls, clangd or the rest are on this host's PATH and it worked
anyway, so there is nothing to apt-install.

Note for the resume project specifically: its content is `.org`, `.html` and
`.css`. There is no built-in org-mode LSP, and `diagnostics resume.html`
returned empty. LSP will matter for code work, not for editing Resume.org.

`opencode debug` is the tool for this class of question — `debug config` shows
the resolved configuration after merging, which answers "did my config actually
take effect" directly instead of by inference.

## Empty <think></think> blocks: two wrong flags, not one

opencode rendered literal empty `<think></think>` pairs. The vendor runner ends
with:

    --reasoning off --reasoning-format none --reasoning-budget -1

Both of the first two were wrong for interactive use, for different reasons.
`--reasoning off` means no thoughts are generated at all, which is why the tags
were empty. `--reasoning-format none` leaves whatever tags do appear *unparsed
inside* `message.content`, which is why they showed up as literal text in the
transcript rather than as a thinking block.

Fixed to `--reasoning on --reasoning-format deepseek`, overridable through
`KAIRIC_REASONING`, `KAIRIC_REASONING_FORMAT` and `KAIRIC_REASONING_BUDGET`.
`deepseek` extracts thoughts into `message.reasoning_content`, the field
opencode renders as a collapsible thinking block. `"reasoning": true` added to
the `code` model in `config/opencode-kairic.jsonc` so opencode expects it.

Verified on a riddle prompt:

    reasoning_content: "We need answer classic riddle... Interpret: all but 9 die mean..."
    content:           "**9 sheep are left.** ..."

Separated correctly. The vendor's choice is right for their purpose — their
whole release is qualified on byte-identical deterministic output, and thinking
tokens would wreck that. It is the third setting in that runner (after the
greedy sampler and the benchmark cache size) that is correct for measurement and
wrong for use. The pattern is worth stating plainly: a benchmark runner is not a
serving configuration, and every default in one should be re-examined rather
than inherited.

Cost: thinking generates extra tokens before the answer, so first-token latency
rises. `KAIRIC_REASONING_BUDGET` caps it if that becomes annoying; -1 is
unrestricted.

## Rebuilt for programming, not for measurement

Nathan's objection was correct and structural: I took the vendor's benchmark
runner as a starting point and patched it reactively three times instead of
designing a serving configuration. Every default in that script exists to make
164 tasks reproducible byte-for-byte. Almost none of them suit an agent.

Full audit, with sources checked rather than reasoned from.

### Sampling was actively wrong, not merely suboptimal

Qwen publishes two sets and they are not interchangeable:

    thinking      temp 1.0  top_p 0.95  top_k 20  min_p 0  presence 0.0
    non-thinking  temp 0.7  top_p 0.80  top_k 20  min_p 0  presence 1.5

I had set the *non-thinking* pair and then enabled thinking. Worse,
presence_penalty 1.5 is the top of Qwen's suggested range and their own docs
warn it "may occasionally result in language mixing and a slight decrease in
model performance". For code it is worse than neutral: a presence penalty
discourages repeating tokens, and repeating identifiers, keywords and
punctuation is exactly what correct code does.

Now temp 1.0 / top_p 0.95 / top_k 20 / min_p 0 / presence 0.0 — which is also
precisely what the GGUF advertises in `general.sampling`. The model told us the
answer and I overrode it with values for the wrong mode.

### One slot was the expensive mistake

The vendor runs `-np 1`; a single-user benchmark never needs more. But
opencode's `general` subagent is documented as "execute multiple units of work
in parallel", and agents inherit the main model unless told otherwise. With one
slot, every parallel subagent both serialises *and* evicts the main session's
KV, forcing a full re-prefill at 228 tok/s — minutes of dead time per subagent
call on a large context.

Now `-np 2`. Context is TOTAL across slots, so this is 131072 per slot rather
than 262144 in one. That trade is right for this workload: 131k is ample for
coding, and protecting the main session's cache is worth far more than context
beyond it. `limit.context` in the opencode config was lowered to match — if it
had stayed at 262144, compaction would fire after the slot had already
overflowed.

Subagents are pinned to slot 1 through a second opencode model entry that
aliases back to the same server model:

    "code-sub": { "id": "code", "options": { "id_slot": 1 } }

Verified in the server log, not assumed:

    slot launch_slot_: id  1 | task 53 | processing task
    slot process_sing: id  0 | task -1 | saving idle slot to prompt cache

### What the research ruled OUT

`--cache-reuse` looks made for this and is a trap. It does not work with
recurrent-state models, and this is a Gated DeltaNet hybrid. Adding it would
have been cargo cult.

`reasoning_effort` (xhigh / medium / low, defaulting to xhigh in this model's
chat template) is worth knowing about but was left alone: current guidance is
xhigh for agentic coding, low for high-volume endpoints. It is the main lever on
thinking-token cost if turns feel slow.

Context shift stays disabled (the default). opencode compacts deliberately;
shifting a recurrent model's window underneath it is a correctness risk.

`-ctxcp 32` is already llama.cpp's default, so the vendor's flag was a no-op.

### Other changes

`--cache-ram` raised 8192 -> 16384. Agent turns share thousands of tokens of
prefix, so cache hits are the difference between a fast turn and a re-prefill,
and there is memory to spare. This is the opposite of the earlier reflex to
shrink it for a ceiling nobody asked for.

opencode model entries now declare `tool_call`, `reasoning` and `attachment`
explicitly instead of relying on inference, and `compaction.reserved` was scaled
to the smaller per-slot window.

### The rule this should have followed from the start

A benchmark harness is tuned to make results reproducible. A serving config is
tuned to make work pleasant. They agree almost nowhere, and inheriting one as a
base for the other silently imports every one of its priorities.

## Reproduction path for a fresh machine

`scripts/setup-kairic.sh`, reachable as `make kairic-setup`, plus a `README.md`
that did not previously exist in this repo.

The script is idempotent and resumable: every step checks before acting, so
re-running after an interrupted 30 GiB download costs a checksum pass rather
than a redownload. It contains no start/stop/run commands, which is deliberate —
it is safe to run while a contract is already serving.

It refuses rather than guesses on the two steps that need root. GTT below 90 GiB
prints the exact grub commands and exits; missing `render` group membership does
the same. Neither is attempted, because nothing in this repo can escalate and a
setup script that silently half-works is worse than one that stops.

Verified without running the heavy path: the llama-swap release asset name the
script constructs (`llama-swap_250_linux_amd64.tar.gz`) resolves 200 against
GitHub and matches the only linux/amd64 asset on that tag; the GTT guard passes
at this machine's 110 GiB and correctly blocks at the ~61 GiB a stock machine
would report; the render-group and image-exists checks resolve correctly.

The README leads with the compatibility-mode figure rather than the faster one,
because the fast path cannot serve a tool call and quoting it as the headline
would mislead exactly the person the document exists for. Third-party
comparisons circulating online were left out — this repo publishes numbers it
measured, with the method beside them.

No CUJ or beads document was produced for this cycle. The work went from spec
straight to measurement and configuration, and Nathan is using the result. That
is a deviation from the pipeline, recorded here rather than papered over.

## Knowledge that existed only in conversation is now in the repo

An audit found nine operational facts that lived only in the session transcript
or buried mid-ledger, where nobody arriving later would find them: the
`KAIRIC_*` tuning variables, `reasoning_effort`, the requirement to restart
opencode after a config change, the `~/.config/opencode/opencode.jsonc` path, the
`id_slot` subagent lane, the `json_schema` fault, the `newgrp` step after
`usermod`, `podman top` as the only reliable way to see a launcher's real argv,
and the two container-dies-silently causes.

`docs/kairic-operations.md` now carries all of it, organised as: what runs
where, the two roles and why the 4B exists, client wiring, a tuning table with
every environment variable and its default, memory and how to watch it, a
troubleshooting section keyed by observed symptom, and a short list of commands
that verify a change actually took effect.

The troubleshooting entries are the failures this cycle actually produced,
written symptom-first — repetition loop, empty think blocks, 400 on tool calls,
hosted models instead of the local provider, LSPs disabled, OOM while every tool
reports plenty free. Each names the cause and the fix rather than the story.

The last section is the one worth keeping: five commands that verify a change
landed, because on this stack reading the config is not evidence. `bash -n`
passed a launcher whose command had been silently truncated by a comment inside
a line continuation, and the server started and served plausible-looking output
for two restarts before `podman top` showed the missing flags.
