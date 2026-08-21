# Ledger — media generation on Strix Halo

Cycle 2. Cycle 1 (the agent suite) is at `.necklace/2026-08-19-local-claude-suite/`
and its findings about this machine are assumed here rather than re-derived.

## 2026-08-20 — What cycle 1 already established

    GPU        Radeon 8060S, gfx1151, RADV: uma 1, fp16 1, bf16 0, KHR_coopmat
    GTT        110.00 GiB (raised from 61.41), carve-out 512 MiB
    /dev/kfd   present and reachable — nathan is now in render and video
    CPU bw     ~80 GB/s of a ~256 GB/s bus; partial offload is a proportional loss
    containers rootless podman 5.7.0, podman-compose, no docker

The `/dev/kfd` line is why this cycle exists. The 3D tool was shelved on Windows
because Docker Desktop on WSL2 exposes `/dev/dxg` and not `/dev/kfd`
(`zoysia-windows-scratch` commit `200f4c3`). That blocker is gone.

## 2026-08-20 — The question this cycle opens with

Two measurements of the same silicon, 22x apart per pixel per step:

    Nathan, 2026-08-08   Qwen-Image 20B, 4 steps, 1328x1328, fp8,
                         native Windows, AMD's tuned comfy-kitchen HIP backend,
                         torch 2.11.0+rocm7.13.0        ->  ~38 s warm, 6.4 s/it

    hec-ovi/text-to-3D   FLUX.2 klein 4B, 4 steps, 1024x1024,
                         stock ComfyUI in a ROCm container, Linux
                                                        ->  514.6 s, ~128 s/it

1.68x more pixels and 5x the parameters, in a thirteenth of the time. A 4B model
cannot legitimately be 22x slower per pixel than a 20B one on the same chip, so
something in the configuration accounts for it. Candidates, none yet tested:
the tuned HIP backend versus stock, fp8 versus higher precision, and klein's
Qwen3-4B text encoder possibly reloading per run.

This decides a hardware question. If the gap closes, a character run drops from
~15 min to ~7 min on this box and the RX 9070 XT is unnecessary. If it does not,
diffusion belongs on the 9070 XT — which Nathan has ruled out as a dependency,
so it would mean the 3D leg is slow or shelved again.

## 2026-08-20 — The 22x narrows before a single thing is run (probe 1)

`kyuz0/amd-strix-halo-comfyui-toolboxes` publishes raw timings in
`docs/benchmark_results.json`, measured on this exact chip with a Fedora ROCm 7
toolbox. Sorted, all cold:

    Qwen-Image 2512, BF16, 4-step LoRA          75.4 s
    Qwen-Image-Edit 2511, BF16, 4-step LoRA    112.7 s
    Qwen-Image 2512, BF16, 20 steps            359.2 s
    LTX2 T2V / I2V, BF16                       615.0 / 616.2 s
    Hunyuan-Video 1.5 720p, 4-step             928.7 / 947.1 s
    Wan 2.2 A14B, 4-step LoRA                 2007.5 / 2028.6 s

This reframes the question. The comparison was never Windows against Linux, and
it was never fp8 against BF16:

    Qwen-Image 20B, 4 steps, BF16, Linux ROCm container      75.4 s
    FLUX.2 klein 4B, 4 steps, Linux ROCm container          514.6 s

**6.8x slower for a model five times smaller, on the same platform.** Nathan's
38 s at fp8 on a tuned Windows backend is roughly 2x better than this BF16
baseline, which is an ordinary amount to gain from precision and tuning. The
outlier is the 3D skill's image stage, and it is an outlier against its own
platform, not only against Nathan's box.

That kills the two explanations I offered when I first found the gap. Remaining
candidates, still untested: klein carries a Qwen3-4B text encoder that may be
reloading per run, and the container may be missing whatever attention path the
toolbox images ship.

### The experiment this sets up

`docker.io/kyuz0/amd-strix-halo-comfyui:latest` ships Qwen-Image FP8 with the
4-step Lightning LoRA — the same configuration behind both reference numbers.

  1. Run Qwen-Image 4-step here. Landing near 75 s calibrates this box against
     the published figure and rules out anything local.
  2. Run FLUX.2 klein 4-step **in the same container**. Near 500 s and the fault
     is the model or its configuration; near 50 s and the fault was the 3D
     skill's container, which is fixable.

Only step 2 answers the question, and it is only meaningful after step 1.

### Rootless GPU passthrough works (probe 2)

The blocker flagged at the end of cycle 1 is not one:

    podman run --rm --device=/dev/kfd --device=/dev/dri --group-add keep-groups
      crw-rw---- 226,128 /dev/dri/renderD128
      crw-rw---- 510,0   /dev/kfd

Both nodes present in a rootless container with no privileged flag. Whether a
ROCm process can actually open them is the next thing the toolbox image settles.

## 2026-08-20 — ROCm works in a rootless container (probe 3)

The thing that killed this on Windows, settled:

    podman run --rm --device=/dev/kfd --device=/dev/dri --group-add keep-groups \
      docker.io/kyuz0/amd-strix-halo-comfyui:latest rocminfo

    Name: gfx1151
    Marketing Name: AMD Radeon 8060S Graphics
    Name: amdgcn-amd-amdhsa--gfx1151

A ROCm process inside a **rootless** container, with no `--privileged`, enumerates
the GPU by its real architecture. `--group-add keep-groups` is what carries the
`render` membership through the user namespace, and that membership only exists
because of the `usermod` in cycle 1.

So the cycle-1 note that "privileged plus device passthrough is exactly where
rootless podman diverges from Docker" was pessimistic. It does not diverge here,
and the 3D skill's `docker-compose.yml` asking for a privileged ComfyUI container
is stricter than this machine actually requires.

Image is `docker.io/kyuz0/amd-strix-halo-comfyui:latest`, 16.2 GB, Fedora with
ROCm 7 from TheRock nightlies. It carries `/opt/ComfyUI`, a venv, the
`comfy-workflows` the published benchmarks were produced from, and fetch scripts
per model family.

### Isolation posture for this cycle, stated rather than assumed

ComfyUI gets one bind mount: a dedicated `~/models-comfy`, nothing else, and
never `$HOME`. Upstream's own instructions use `toolbox`, which mounts the home
directory wholesale; that is convenient and it is not what Nathan asked for.
ComfyUI is a model runner rather than an agent choosing what to touch, so a
scoped model directory is the right line — the same line the contract proxy sits
on in cycle 1.

Downloading Qwen-Image 2512 fp8 plus the 4-step Lightning LoRA now, which is the
exact configuration behind both reference numbers.

## 2026-08-20 — Torch sees the raised ceiling, and fp16 beats bf16 (probe 4)

    torch      2.14.0a0+rocm7.15.0a20260721
    hip        7.15.0
    available  True
    device     AMD Radeon 8060S Graphics, gfx1151
    vram       110.0 GiB

**PyTorch reports 110.0 GiB.** The GTT change from cycle 1 is not an LLM-only
win — the diffusion stack sees the whole raised pool, which is what makes the
20B-class image models and the 19B video models loadable here at all.

GEMM throughput, warmed up, 30 iterations:

    fp16  n=2048    15.3 TFLOP/s
    fp16  n=4096    10.9 TFLOP/s
    fp16  n=8192     9.5 TFLOP/s
    bf16  n=4096     8.4 TFLOP/s

Two things fall out.

**Throughput degrades as the matrix grows**, 15.3 down to 9.5. The working set
outgrows cache and the operands stream from LPDDR5X, so even a compute-bound
kernel ends up bandwidth-limited at scale. This is the same wall the LLM work
hit from the other side in cycle 1.

**bf16 is ~23% slower than fp16** at identical size. Every workflow in the
published benchmark set is BF16, which is a large part of why Nathan's fp8 run
came in at roughly half their number. It also means precision choice on this
chip is a throughput decision and not only a quality one — the same shape as the
quant finding in cycle 1, where the file you pick matters more than the size
suggests.

A first attempt at this measurement averaged the JIT/autotune pass into the
result and reported 10.8 TFLOP/s for fp16 at n=4096. Warmed up it is 10.9, so
the error happened to be small, but it was luck rather than method.

## 2026-08-20 — A concrete hypothesis for the 22x (probe 5)

Located the exact weights the 3D skill names, in
`Comfy-Org/vae-text-encorder-for-flux-klein-4b`:

    split_files/diffusion_models/flux-2-klein-4b.safetensors     7.75 GB
    split_files/text_encoders/qwen_3_4b.safetensors              8.04 GB
    split_files/vae/flux2-vae.safetensors                        0.34 GB

**The text encoder is larger than the diffusion model.** FLUX.2 klein "4B" is
4B of transformer plus a Qwen3-4B text encoder, so a run touches roughly 16 GB
of weights, not 8. If ComfyUI evicts and reloads the encoder between runs — the
default when memory is tight, and the skill's own timings show a mesh run
slowing from 345 s to 1084 s purely because the image model stayed resident —
then a large part of that 514 s is model loading rather than sampling.

That is now the leading explanation, and it predicts something testable: the
*second* image in a session should be far faster than the first. The skill's
published table reports only single runs (514.6 s for a 1024 square, 519.1 s for
a portrait), which is consistent with every one of them paying a cold load.

Lighter variants exist and are worth measuring against the same prompt:

    flux-2-klein-4b-fp8.safetensors        4.07 GB   (vs 7.75 bf16)
    qwen_3_4b_fp4_flux2.safetensors        3.85 GB   (vs 8.04)

7.9 GB against 16.1 GB for the pair. Given probe 4 measured fp16 beating bf16 by
23% on raw GEMM, and given 110 GiB of headroom means nothing needs to be evicted
at all, the fast path may simply be "load fp8, keep everything resident".

Both sets downloading in parallel: the exact configuration the skill specifies,
so its number can be reproduced, and the lighter one, so the gap can be
attributed rather than guessed at.

## 2026-08-20 — Box calibrated, and half of a "cold" run is loading (probe 6)

ComfyUI from the toolbox image, GPU passed through rootless, reporting
`cuda:0 AMD Radeon 8060S Graphics : native` with 110 GiB. Qwen-Image 2512 fp8,
4-step Lightning LoRA, via `repl/imgbench.py` against the running server:

    first run of the session      77.7 s
    weights resident, reseeded    38.3 s
                                  40.8 s
                                  57.8 s

Reference points:

    kyuz0 published, BF16, cold                    75.4 s
    Nathan, 2026-08-08, Windows comfy-kitchen fp8  36.6 - 38.6 s warm

**77.7 against a published 75.4 calibrates this box within 3%.** Nothing local
is wrong, and step 1 of the experiment is answered.

**38.3 s warm lands on Nathan's Windows number exactly.** So for diffusion,
Linux with the stock ROCm toolbox is *equal* to the tuned Windows stack, not
better. What Linux buys is `/dev/kfd`, which is what the 3D tool needs and what
WSL2 could not give. That is the honest version of "Linux should be faster" from
the opening brief: it is not faster here, it is unblocking.

**Roughly half of a cold run is weight loading**, 77.7 against ~39. That is the
number the 22x hypothesis needed.

### A measurement mistake worth keeping

The first attempt reported `cold 77.7 s / warm 1.0 s` and the warm figure was
nonsense. ComfyUI caches by graph hash, so re-queuing an identical graph returns
the previous result in about a second without executing anything. The harness
now varies the seed on every run and warns if it finds no seed input to vary.

A 1.0 s "warm" result would have been a spectacular finding, and it was the
tool measuring itself. Worth the reminder that a result far better than expected
deserves the same scrutiny as one far worse.
