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
