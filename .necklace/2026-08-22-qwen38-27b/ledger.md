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
