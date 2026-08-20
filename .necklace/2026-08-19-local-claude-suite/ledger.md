# Ledger — local Claude-suite on Strix Halo

Append-only. Newest at the bottom.

## 2026-08-19 — Machine baseline (probe 1)

Ran hardware/software inventory on ZOYSIA before proposing anything.

    CPU      AMD RYZEN AI MAX+ PRO 395 w/ Radeon 8060S, 16C/32T
    GPU      c3:00.0 Strix Halo [1002:1586] rev d1  (gfx1151)
    RAM      122 GiB usable (128 GB unified LPDDR5X)
    Disk     3.1T root, 2.6T free
    OS       Ubuntu 26.04 LTS (resolute), kernel 7.0.0-29-generic
    Node     v24.19.0 (nvm)   Python 3.14.7 (linuxbrew)   podman 5.7.0

Clean slate for inference. None of ollama / llama.cpp / vllm / opencode / uv /
docker / huggingface-cli present.

### Two findings that shape everything downstream

**1. GTT is capped at 61.4 GiB, not 122.**

    /sys/class/drm/card1/device/mem_info_vram_total   536870912      (512 MiB)
    /sys/class/drm/card1/device/mem_info_gtt_total  65937801216      (61.4 GiB)
    /sys/module/ttm/parameters/pages_limit            16098096      (= 61.4 GiB)

The 512 MiB VRAM figure is the BIOS UMA carve-out and is *correct* for Linux —
on Strix Halo the GPU reaches host memory through GTT, so a small carve-out
leaves more for the flexible pool. But GTT defaults to half of RAM, which puts
a hard ceiling on model size well below what the box can actually hold. Raising
it is an `amdgpu.gttsize` / `ttm.pages_limit` boot-arg change, so it is a
reboot, so it belongs in the plan rather than being discovered mid-benchmark.

**2. nathan is not in `render`.**

    /dev/kfd  crw-rw----+ root render
    id -> nathan adm cdrom sudo dip plugdev users lpadmin lxd

The ROCm compute node exists but is not reachable by the user account. Any
ROCm path is dead on arrival until this is fixed, and it needs a re-login to
take effect. Worth knowing before blaming ROCm for a permission error.

## 2026-08-19 — Distro / runtime availability (probe 2)

    mesa-vulkan-drivers   26.0.3-1ubuntu1     already installed
    libvulkan1            1.4.341.0-1         already installed
    hipcc (universe)      7.1.1+dfsg-0ubuntu1 available, not installed

Ubuntu 26.04 universe carries a Debian-packaged ROCm 7.1.1. RADV is already on
the box and costs nothing.

## 2026-08-19 — llama.cpp Vulkan works out of the box (probe 3)

Downloaded the prebuilt `llama-b10502-bin-ubuntu-vulkan-x64` release. No sudo,
no build, no ROCm.

    ggml_vulkan: 0 = Radeon 8060S Graphics (RADV STRIX_HALO) (radv)
      uma: 1 | fp16: 1 | bf16: 0 | fp4: 0 | warp 64 | shmem 65536
      int dot: 1 | matrix cores: KHR_coopmat
    Vulkan0: Radeon 8060S Graphics (63395 MiB, 56235 MiB free)

`uma: 1` matters — the Vulkan backend takes the zero-copy path, so weights are
not duplicated between host and device. `KHR_coopmat` means the matrix cores
are reachable from RADV. `bf16: 0`, so BF16 GGUFs are off the table; fp16 and
the int-dot quant kernels are the fast paths.

Note the 63395 MiB figure is the GTT ceiling reappearing. This is the number
that would have to move to hold a 122B-class model.

There is **no prebuilt HIP/ROCm binary** in the llama.cpp release matrix. The
ROCm path is: install ROCm (sudo), build from source (~30 min), every upgrade.
The Vulkan path is: untar.

### Aside, discovered while checking sudo

`sudo -n` fails — this session cannot escalate. Anything needing root (apt,
boot args, group changes) has to be handed to Nathan as a command to run, not
executed here. Shaped the whole plan toward user-level installs.

## 2026-08-19 — Memory bandwidth, and why CPU offload is not free (probe 4)

`repl/membw.c` — 4 GiB working set, OpenMP reduction, three reps:

    read 4.0 GiB in 0.0566 s ->  75.9 GB/s
    read 4.0 GiB in 0.0505 s ->  85.1 GB/s
    read 4.0 GiB in 0.0541 s ->  79.4 GB/s

~80 GB/s from the CPU side against a 256-bit LPDDR5X bus whose theoretical
ceiling is ~256 GB/s. The 16 Zen 5 cores cannot saturate the controller; the
iGPU can get far closer.

This settles a question that would otherwise have been argued from intuition:
"it is all one pool of memory, so CPU offload costs nothing" is **wrong on this
box**. Any layer that lands on the CPU runs against a third of the bandwidth.
Decode is bandwidth-bound, so a partial offload is a proportional slowdown, not
a rounding error. Everything goes on the GPU or the plan is broken.

Corollary for sizing: decode ceiling ~= achievable-bandwidth / bytes-read-per-
token. For a 3B-active MoE at ~4.5 bits/weight that is ~1.7 GB/token, so ~100
t/s if the GPU reaches 170 GB/s. Published Vulkan numbers for gfx1151 on a
comparable model land near 80 t/s, which is consistent.

### GTT and VRAM, measured

    mem_info_vram_total       0.50 GiB   (BIOS UMA carve-out)
    mem_info_vram_used        0.48 GiB   (display framebuffer — already full)
    mem_info_gtt_total       61.41 GiB
    mem_info_gtt_used         6.51 GiB

All model weights land in GTT. `ttm.pages_limit` and `amdgpu.gttsize` are both
root-owned sysfs knobs; changing them for real is a boot-arg edit.

## 2026-08-19 — First real benchmark, and a wrong guess corrected (probe 5)

Qwen3.6-35B-A3B UD-Q4_K_XL, 20.81 GiB on disk, llama.cpp b10502 Vulkan:

    pp512     321.83 ± 88.49 t/s
    pp4096    255.42 ±  0.80 t/s
    tg128      25.93 ±  0.62 t/s

Published Vulkan figures for Qwen3-Coder-30B-A3B on the same silicon are
1115 pp512 / 97.7 tg128. Same active-parameter count, a quarter of the decode.

My first move was to blame a concurrent model download for stealing bandwidth.
It had already died — stalled at 24.94 GB — and load average was 1.26. The
number is real. Recording the wrong guess because it is the kind that would
otherwise get made twice.

### What it actually is

Sampled `gpu_busy_percent` every 2 s through a clean re-run:

    2 4 42 79 97 99 95 98 97 98 98 98 98

The GPU is saturated. 25.9 t/s against ~1.7 GB of weights per token is roughly
44 GB/s of traffic, a fifth of what this GPU pulls when it is actually
bandwidth-limited. Saturated and slow at 44 GB/s means the shaders are busy
doing something other than streaming weights.

Qwen3.6-35B-A3B is a hybrid: `10 × (3 × (Gated DeltaNet → MoE) → 1 × (Gated
Attention → MoE))`. Three quarters of its blocks use linear attention, not
softmax attention. The published comparison model is a conventional MoE. The
difference is architecture, not size.

**Decode on this model is compute-bound, not bandwidth-bound.** That inverts
the standard local-LLM sizing rule — "decode is bandwidth-bound, so run the
largest model that fits" — for this whole class of model.

### Two predictions this makes, both cheap to test

1. If decode is compute-bound rather than bandwidth-bound, Q6_K_XL (31.8 GB,
   ~50% more bytes per token) should decode at close to Q4's rate. A
   bandwidth-bound model would lose about a third.
2. If the DeltaNet kernels are specifically where it goes, Qwen3-Coder-30B-A3B
   — conventional attention, same 3 B active — should decode several times
   faster on the same backend and binary.

Both downloads are running. Harness is `repl/bench.sh`, which now refuses to
start while a `.gguf` download is live and records `gpu_busy_percent` next to
every number, because those two mistakes both happened today.

### Why this raises the stakes on the backend decision

Nathan chose "build both, pick per model." That was a good call on prefill
grounds and is now a better one: a compute-bound decode is a kernel-quality
problem, and kernel quality is exactly where ROCm and RADV differ most. The
published Vulkan-wins-decode result was measured on conventional attention.
For DeltaNet the ranking may well invert. This moves benchmarking both
backends from nice-to-have to load-bearing.

## 2026-08-19 — Both predictions confirmed, and they are two effects (probe 6)

Machine quiet, nothing downloading, `repl/bench.sh` guard satisfied. Same
binary (b10502 Vulkan), same flags, same run.

    model                 attention      quant       size        pp512    tg128
    Qwen3.6-35B-A3B       hybrid DN      Q4_K_XL   20.81 GiB     321.8     25.9
    Qwen3.6-35B-A3B       hybrid DN      Q6_K      29.65 GiB     641.1     46.6
    Qwen3-Coder-30B-A3B   conventional   Q4_K_XL   16.45 GiB     773.8     78.6

**Prediction 1 was right in direction and badly wrong in magnitude.** I expected
Q6 to hold roughly level with Q4 if decode was compute-bound. It did not hold
level — it went 80% *faster* while being 50% larger. A bigger quant that decodes
faster cannot be explained by bandwidth under any reading. The Q4_K path on
RADV is simply a worse shader than the Q6_K path.

**Prediction 2 was right.** Conventional attention at the same quant decodes
3.0x faster than hybrid DeltaNet. So the architecture effect I claimed is real
and roughly the size I guessed.

The two are independent and multiply. Nothing in probe 5 distinguished them,
because probe 5 had only one data point; I attributed the whole gap to DeltaNet
and would have shipped that as the finding.

### The sanity check that matters

Qwen3-Coder-30B-A3B at 78.6 t/s sits close to the published 97.7 for the same
model at Q4_K_S on this silicon. Different quant, different build. Close enough
that the box is behaving normally for a conventional model, which rules out the
boring explanation — nothing systemic is throttling this machine. The slow
numbers are specific to what was being run, not to the machine.

### What this does to the plan

Selection is a three-way interaction — architecture × quant × backend — and not
one of the three is predictable from a model card. The spec's Approach already
said "benchmark before assigning roles"; this is now the justification rather
than a precaution.

One immediately actionable consequence: **Qwen3.6-35B-A3B should be run at Q6_K,
never at Q4_K_XL.** Higher quality and 80% more throughput at the cost of 9 GiB
on a box with 122. There is no tradeoff to weigh; Q4 is dominated.

Downloading Q8_0 (36.9 GB) to find where the trend turns over. If Q8 also holds
near 46 t/s then this box should run near-lossless quants as a matter of course,
which is a different default from the one everyone assumes.

### Aside on `gpu_busy_percent`

Every run shows a long low-utilisation head (7-10%) before the ramp to 97-98%.
That is the model being read off NVMe into page cache, not the benchmark. Worth
knowing before someone reads a utilisation trace and concludes the GPU is idle.

## 2026-08-19 — Q8_0 flattens the curve (probe 7)

    Qwen3.6-35B-A3B   Q4_K_XL   20.81 GiB    322 pp512    25.9 tg128
    Qwen3.6-35B-A3B   Q6_K      29.65 GiB    641 pp512    46.6 tg128
    Qwen3.6-35B-A3B   Q8_0      34.36 GiB    705 pp512    46.3 tg128

Q6 to Q8 is 16% more bytes per token for zero decode cost, and 10% *better*
prefill. A bandwidth-bound decode would have lost 16%. This is the clean proof;
probe 6 was the surprise, this is the confirmation.

Ranking on RADV for this model: **Q8_0 >= Q6_K >> Q4_K_XL**. Q8_0 is a uniform
8-bit block format with a trivial dequant path, which is presumably why it beats
the more elaborate Q6_K at prefill despite being larger.

Practical upshot: run the near-lossless quant. 34.36 GiB of 122, at full speed.
The universal advice — quantise hard so it fits and so it runs fast — is exactly
backwards on this hardware, and only measurement showed it.

### The ambiguity this leaves, and why it changes the advice

The slow file is unsloth's `UD-Q4_K_XL`. Unsloth's Ultra Dynamic quants mix
tensor types, putting IQ-family types on some tensors. llama-bench reports the
file as "Q4_K - Medium", which is its read of the dominant type, not proof that
every tensor is Q4_K.

So two different lessons are still consistent with the data:

  A. Q4_K is a poor kernel on RADV        -> avoid Q4_K, any packager
  B. the mixed IQ tensors are the problem -> avoid dynamic mixed quants on RADV,
                                             plain Q4_K is fine

These give opposite advice about a plain Q4_K_M file. Downloading bartowski's
`Qwen_Qwen3.6-35B-A3B-Q4_K_M.gguf` (22.29 GB), which is a conventional
non-dynamic quant of the same model, to settle it. If it lands near 25 t/s the
answer is A; near 46 t/s and the answer is B.

## 2026-08-19 — The packager was the variable all along (probe 8)

bartowski's plain `Q4_K_M`, same model, same quant family, non-dynamic:

    Qwen3.6-35B-A3B  UD-Q4_K_XL (unsloth)    20.81 GiB    322 pp512    25.9 tg128
    Qwen3.6-35B-A3B  Q4_K_M     (bartowski)  20.74 GiB    707 pp512    58.0 tg128

Answer is B. Identical size, 2.24x apart on decode and 2.20x on prefill. The
penalty is unsloth's Ultra Dynamic packaging — the IQ-family tensors it mixes in
— not Q4_K. And plain Q4_K_M is now the fastest thing measured on this model,
ahead of both Q6_K and Q8_0.

Full picture for Qwen3.6-35B-A3B on RADV / b10502:

    Q4_K_M     plain     20.74 GiB    707 pp    58.0 tg
    Q8_0       plain     34.36 GiB    705 pp    46.3 tg
    Q6_K       plain     29.65 GiB    641 pp    46.6 tg
    UD-Q4_K_XL dynamic   20.81 GiB    322 pp    25.9 tg

### Correcting probe 7's conclusion

Probe 7 concluded "Q4 is strictly dominated, run Q8_0." That was drawn from the
UD file alone and it is wrong. Stated to Nathan before this probe ran, so it is
worth being explicit about what replaces it.

The regime is mixed, not uniformly compute-bound:

  - Q6 -> Q8 : 16% more bytes, 0% slower. Fully compute-bound. Size is free.
  - Q4 -> Q6 : 43% more bytes, 20% slower. Partly bandwidth-sensitive.
  - dynamic quants: 2.2x penalty at any size. A packaging artifact, not physics.

So the crossover sits near Q6. Below it, size still costs something; above it,
nothing. Revised advice: plain Q4_K_M for throughput, Q8_0 for near-lossless
quality at 80% of that throughput, and never a dynamic mixed quant on this
driver.

### What it does to the architecture comparison

The 3.0x architecture gap in probe 6 was measured UD-against-UD, so it is still
apples-to-apples and still real. But the *roster* conclusion drawn from it is
now suspect. Qwen3.6-35B-A3B on a plain quant does 58.0 t/s — with vision, a
262k context, and much stronger reasoning — against Qwen3-Coder-30B-A3B's 78.6
on a UD quant that we now know is penalised.

I told Nathan his daily driver was probably the older conventional model. That
may well be wrong, and his original instinct about Qwen3.6 right. Downloading
lmstudio-community's plain `Q4_K_M` of the coder (18.63 GB) so the comparison is
plain-against-plain. If the coder gains the same ~2.2x it stays far ahead; if it
gains little, the two are close and Qwen3.6 wins the roster on capability.

Also noted: `pkill -f "Qwen_Qwen3-Coder"` killed the calling shell, because the
pattern matched the wrapper `bash -c` that contained it. Same self-match that
made `pgrep -f curl.*gguf` report phantom downloads twice today. `-f` matches
full command lines including one's own.

## 2026-08-20 — Prior art recovered, and scope opens to media generation

Nathan pointed at `soniccyclone/zoysia-wsl-scratch`. The ComfyUI work is not
there — it is in `soniccyclone/zoysia-windows-scratch` under
`strix-halo-media-ai/`, deleted in `6cd87ac "Cancel all LLM image gen because it
is not useful for game asset generation"` and recovered from `6cd87ac~1`.

What the wsl-scratch repo does carry: a Lemonade Server endpoint on port 13305
serving `gpt-oss-120b-mxfp4-fixed`, and a vision-input plan. Both worth knowing;
neither is image generation.

### His own findings, which the plan should not re-derive

Measured on this exact chip, native Windows, AMD's tuned `comfy-kitchen` HIP
backend, torch 2.11.0+rocm7.13.0, fp8:

    Qwen-Image 20B, 4-step, 1328x1328   cold 124.7 s   warm 36.6-38.6 s
                                        sampler ~6.4 s/it
    LTX-2 19B video, 832x480, 49 frames cold 212 s     warm ~90-100 s

Verdicts he reached by human eval, not metric:

  - **Pixel art: SDXL + Pixel-Art-XL beat Qwen-Image on quality AND speed.**
    A small style-trained specialist beats a large generalist for a narrow
    style. He notes this is the inverse of the general image/edit case.
  - **Video: LTX-2 beat Wan 2.2** on composition, motion, prompt adherence,
    and it is faster and carries audio.
  - **Hard principle: style is generated, never post-applied.** The NES-lock
    workflow was deleted. Mechanical Floyd-Steinberg carpet-bombs dithering
    uniformly, which is the opposite of deliberate placement. The only legal
    post-step is grid recovery of pixels the model already composed.

And, independently of my probe 5-8 work: "**Compute-bound, not load-bound.**
warm ~= cold on every workflow. VRAM = capacity, not speed." Two unrelated
workloads, same conclusion about this machine.

### The blocker that no longer exists

`200f4c3 Verify 3D tool needs /dev/kfd: WSL2 gives /dev/dxg, needs bare-metal
Linux`. The 3D tool was shelved because Docker Desktop on WSL2 exposes
`/dev/dxg` and not `/dev/kfd`. Probe 1 found `/dev/kfd` present on this box. The
reason it was abandoned is gone; only the `render` group membership remains, and
that is already on the list for the ROCm leg.

### hec-ovi/text-to-3D-skill

Built for gfx1151 specifically. FLUX.2 klein through ComfyUI on ROCm produces a
reference image, a trimmed C++/GGML TRELLIS.2 fork runs Vulkan-only for the
mesh, SkinTokens rigs humanoids on ROCm. No Blender, no CUDA. The two stacks
talk over HTTP (`T2M_ENGINE=http://host.docker.internal:8189`) and are, in the
author's words, separate projects on purpose — so the seam between image and
mesh is a URL, not a shared process.

Its published timings on a box like this one:

    harness cold 853 s     harness warm 38 s
    image 1024 square, FLUX.2 klein, 4 steps        514.6 s
    mesh res 1024, 12K faces, warm                  345.3 s
    mesh res 1024, 12K faces, image model resident 1084.4 s
    rig 11,168 vertices                              13.0 s

### The contradiction worth chasing before buying hardware

The author flags the image stage as the surprise: four steps of a distilled 4B
model taking eight and a half minutes. But Nathan measured 20B Qwen-Image at
1328x1328 — 1.68x the pixels, 5x the parameters — in 38 s warm on the same
silicon. Per pixel per step that is roughly **22x apart**.

A 4B model cannot legitimately be 22x slower per pixel than a 20B one on the
same chip. The difference is configuration, and the visible candidates are that
Nathan ran AMD's tuned `comfy-kitchen` HIP backend at fp8 while the skill runs
stock ComfyUI in a ROCm container, plus klein carrying a Qwen3-4B text encoder
that may be reloading per run.

This matters because it decides a hardware question. If the image stage is
fixable to Nathan's rate, a character run drops from ~15 min to ~7 min on this
box alone and the second machine is unnecessary for 3D. If it is not, the image
stage belongs on the RX 9070 XT.

### RX 9070 XT, what is actually known

AMD's published RDNA4 figure (R9700, 32 GB, gfx1201, ROCm 7.1): SDXL 1024x1024,
20 steps, 4.6 it/s. Normalising Nathan's 6.4 s/it for the 7.7x parameter gap
between Qwen-Image and SDXL puts this box near 0.83 s/it for an SDXL-class
model. So RDNA4 is roughly **4x** faster for diffusion, consistent with the raw
FP16 ratio.

The 16 GB cap, not the speed, is what decides placement:

    fits  SDXL + Pixel-Art-XL       ~7 GB     4x faster there
    fits  FLUX.2 klein 4B + TE fp8  ~8 GB     4x faster there
    no    Qwen-Image 20B fp8       ~20 GB
    no    LTX-2 19B video          ~19 GB
    no    TRELLIS.2 GGUF set    ~16-20 GB

Unverified: whether that machine runs Linux, and whether it is on this LAN. Both
are questions for Nathan; neither is answerable from here.

### New in the field since his Aug-11 analysis

`Limbicnation/pixel-art-lora` is a rank-64 LoRA on FLUX.2-klein-4B, Apache 2.0,
trained on 500 CC0 images. 512x512 RGBA with transparent backgrounds, 4 steps,
CFG 1.0, LoRA strength 0.85-1.4. That is precisely the "style-trained LoRA so
the model generates that style natively" his pixel-art plan called for and could
only find SDXL candidates for. It also puts FLUX.2 klein on both the sprite
track and the 3D pipeline's image stage — one 4B model serving both.

## 2026-08-20 — Media scope parked as cycle 2, with its preconditions probed

Nathan's calls:

  - The RX 9070 XT is on the LAN but is **not to be depended on**. It is an
    escape hatch for fast iteration sessions, not a planned tier. Everything is
    planned to run on Strix Halo alone.
  - The 22x image-stage gap is chased **first** inside the media cycle, because
    it decides whether that second machine matters at all.
  - Media gets its **own necklace cycle, after the agent suite lands**. This
    spec stays scoped to Code/Cowork/Design over one serving contract.
  - Pixel art is an **A/B with human eval** — FLUX.2 klein + the Limbicnation
    LoRA against SDXL + Pixel-Art-XL, same subjects. Same method that produced
    his SDXL and LTX-2 verdicts.

So spec.md is deliberately not expanded. What follows is the starting state for
cycle 2, probed today so that cycle does not begin by rediscovering it.

### Preconditions on this box

    podman            5.7.0, rootless
    podman-compose    ~/.local/bin/podman-compose  (podman's external provider)
    docker            absent
    render gid        990
    video gid         44
    nathan groups     in neither render nor video
    free disk         2.5 T

Two of these are load-bearing and neither is obvious.

**The skill wants Docker with Compose; this box has rootless podman.** The
ComfyUI container in that stack is described as privileged and holding
`/dev/kfd`, while the mesh engine gets the render node only. Privileged plus
device passthrough is exactly where rootless podman diverges from Docker. This
is the first thing cycle 2 should test, before any weights are fetched.

**The `render` and `video` gids here are 990 and 44** — which are, by
coincidence or convention, the literal values in the skill's `.env.example`. So
that file is likely usable unedited, but only after the group membership exists.

Membership in `render` is now blocking three separate things: the ROCm leg of
the agent suite, the ComfyUI container, and the SkinTokens rig service. It is
one command and a re-login, and it should happen at the same time as the GTT
boot-argument reboot rather than as its own interruption.

## 2026-08-20 — GTT change written down properly

Nathan asked whether the exact commands had reached the ledger before he
rebooted. They had not — they existed only in chat. That is precisely the
failure mode the ledger exists to prevent, and it would have cost the rollback
path at the moment it was needed.

Full procedure now in **`repl/gtt-change.md`**: measured before-state, the BIOS
check (verify, do not change — the carve-out is already at the 512 MiB minimum
and raising it would be actively wrong on Linux), the exact commands, a
verify-before-reboot step, a verify-after-reboot step, and rollback for both the
boots-but-broken and does-not-boot cases.

Target is 110 GiB: `amdgpu.gttsize=112640` (MiB) and `ttm.pages_limit=28835840`
(4 KiB pages). The two units differ and must agree or the lower silently wins.
110 leaves 12.8 GiB for the OS; 120 would leave 2.8 and risks the GPU squeezing
userspace into OOM.

Nothing has been executed. Every command is Nathan's to run — this session
cannot escalate.

### Rule this establishes for the rest of the work

A command that changes machine state gets written to the planning directory
**before** it is handed over, not after it is run. Chat is not durable; the
rollback is worth more than the change and is needed at exactly the moment the
chat is unreachable.

## 2026-08-20 — GTT change landed (probe 9)

Nathan ran the procedure in `repl/gtt-change.md`. Pre-flight passed: the source
config carried exactly one changed line against `grub.bak`, and
`grep -c "amdgpu.gttsize=112640" /boot/grub/grub.cfg` returned 2.

After the reboot:

    mem_info_gtt_total     118111600640    110.00 GiB   (was 61.41)
    ttm.pages_limit            28835840                 (was 16098096)
    mem_info_vram_total       536870912    512 MiB      unchanged, as intended
    id -nG                 render, video                both present
    /dev/kfd               crw-rw----+ root render      now reachable

    RADV: Radeon 8060S Graphics (113152 MiB, 110920 MiB free)
                                        was (63395 MiB, 56235 MiB free)

+48.6 GiB of addressable GPU memory. The carve-out did not move, which is the
point: the memory came from raising the borrowing ceiling, not from stealing it
from the OS.

### Regression check — it got faster

Daily driver, bartowski plain Q4_K_M, same binary and flags:

                  before (61 GiB)      after (110 GiB)
    pp512      707.42 ± 12.12       811.46 ± 30.57      +14.7%
    tg128       57.98 ±  0.44        59.64 ±  0.05       +2.9%

Both outside their error bars. Attribution is not clean, though: this is a fresh
boot, and the "before" run happened on a machine that had spent the day pulling
141 GB of GGUFs through its page cache. Fragmentation and a bigger ceiling are
confounded and this probe cannot separate them. Recorded as measured rather than
explained.

### What this unlocks

108.3 GiB free to the GPU. Qwen3.5-122B-A10B at Q4_K_XL is roughly 70 GB, so the
deep tier the spec assumed is now actually loadable, with headroom for a KV
cache at long context. Before the change it was 14 GB short of fitting.

Three things that were blocked on `render` membership are now unblocked: the
ROCm build for the coding leg, the ComfyUI container in the media cycle, and the
SkinTokens rig service.

## 2026-08-20 — 122B deep tier, and a refinement of the quant finding

`Qwen/Qwen3.5-122B-A10B` is **the same hybrid architecture as the 35B**: 12x
repeating `Gated DeltaNet -> MoE` / `Gated Attention -> MoE`, 256 experts, 8
routed plus 1 shared, 10 B active, 262 k native context, and a vision encoder
with an mmproj available. So probe 8's finding applies to it directly, and the
selection is a plain quant rather than a dynamic one.

Two candidates pulling:

    lmstudio-community  Q4_K_M homogeneous plain          74.21 GB
    Beinsezii           q80-q6k_ffn, hand-mixed for Halo  94.79 GiB, with MTP

### The HALO quant refines rather than contradicts probe 8

It is a *mixed* quant, which on the face of it is the thing probe 8 warned
against. Its `tensor_types.txt` says otherwise:

    .          = Q8_0     attention, embeddings
    ffn        = Q6_K
    shexp      = Q8_0     shared expert
    nextn      = Q8_0     MTP head
    ssm_alpha  = F32
    ssm_beta   = F32

Zero IQ-family tensors, and the DeltaNet state-space parameters left at **F32**
— untouched by quantisation entirely. That is precisely the path probe 6 and
probe 8 identified as the expensive one on RADV, and the author appears to have
reached the same conclusion independently and answered it by declining to
quantise there.

So the rule stated in probe 8 was too coarse. Corrected:

    wrong:  mixed quants are slow on RADV
    right:  IQ-family types on DeltaNet-path tensors are slow on RADV

Mixing is fine, and may be better than homogeneous, as long as every type used
has a good kernel and the SSM parameters are left alone. Unsloth's UD scheme
substitutes IQ types by bit-budget without regard for which path a tensor sits
in; this one is hand-placed with the architecture in mind.

The author's published numbers are ROCm, not Vulkan: pp2048 275.0, tg256 16.62,
and holding 16.68 tg at 8 k depth. Worth noting that decode barely moves with
context depth there, which is what the linear-attention layers are supposed to
buy.

### The A/B this sets up

Homogeneous-plain against hand-mixed-plain, both on Vulkan, same harness. It
tests whether the refinement above is real: if the 94.79 GiB mixed quant beats
the 74.21 GB homogeneous one on decode, then tensor placement matters more than
total size, which is the strongest form of today's lesson.

Fit is the open risk on the larger one. 94.79 GiB against 108.3 GiB free leaves
roughly 13 GiB for KV cache; the author claims 100-200 k context depending on
TTM settings, more with vision disabled. That is measurable rather than
arguable.

## 2026-08-20 — Three download mistakes worth not repeating

**1. Files over ~50 GB are split by Hugging Face.** The single-file URL for the
74 GB quant returned a 404 with a 15-byte body, and because the fetch loop only
checked curl's exit code on a `-sfL` request it retried the same 404 twelve
times in silence. The real names carry `-00001-of-00002`. My earlier size survey
had collapsed those suffixes with a regex to total the parts, which is exactly
how the real filename got lost before it was ever used.

**2. Serialising the downloads was wrong, and Nathan called it.** The reasoning
was bandwidth contention; the reality is that Hugging Face throttles per
connection. Measured:

    one stream       2.5 - 17 MB/s
    five streams   114.6 MB/s  (917 Mbit/s, saturating his gigabit line)

179 GB went from a multi-hour serial fetch to about 25 minutes. The lesson is
that "don't contend for a shared resource" is only right when the shared
resource is the bottleneck, and here it never was.

**3. `pkill -f <pattern>` killed the calling shell. Again.** Noted after probe 8
and repeated within the hour, this time taking an unwritten heredoc with it. The
wrapper `bash -c '...'` contains the pattern as a literal string, so `-f` matches
it. Use `pgrep -x curl` and kill by pid.

`repl/fetch-122b.sh` now carries all three fixes: real multipart URLs, five
parallel streams, and a marker file written only after curl exits clean so a
truncated file can never look finished to `bench.sh`.

### Actual sizes, corrected

    lmstudio Q4_K_M   40.01 + 34.20      =  74.21 GB   (69.1 GiB)
    Beinsezii HALO    single file        = 103.93 GB   (96.8 GiB)

The HALO figure is not the 94.79 GiB in its README — that number is a comparison
row for a different quant. At 96.8 GiB against 108.3 GiB free it leaves roughly
11.5 GiB for KV cache. It would not have fit at a 96 GiB GTT ceiling, so the
choice of 110 over 96 turned out to be load-bearing rather than cautious.

## 2026-08-20 — 122B A/B: my prediction was wrong, and the regimes resolve (probe 10)

    lmstudio  Q4_K_M homogeneous   69.10 GiB   215.0 pp512   26.36 tg128
    Beinsezii q80-q6k_ffn mixed    96.78 GiB   170.0 pp512   19.81 tg128

I predicted the hand-mixed quant would win, on the reasoning that tensor
placement had beaten raw size all day. It lost by 1.33x on decode. Written down
because the reasoning was sound and the conclusion still wrong, which is the
kind that repeats.

### What was actually going on all day

    35B-A3B    3B active    1.66x bytes -> 1.25x slower    sub-linear
    122B-A10B 10B active    1.40x bytes -> 1.33x slower    proportional

The 35B is compute-bound; the 122B is bandwidth-bound. Active parameters move a
model across that line. Every result from probe 5 onward fits this without
special pleading: Q6 to Q8 was free at 3 B active because the shaders were the
limit, and size costs one-for-one at 10 B active because the memory controller
is. The IQ-on-DeltaNet penalty is a separate, orthogonal effect about kernel
quality, and it is still real.

### Two caveats that could overturn the ranking, both unsettled

`llama-bench` never speculates, so the HALO quant's MTP head is dead weight in
this measurement while still costing bandwidth — its headline feature was
switched off for the test that judged it. And its author tuned against ROCm
kernels, not RADV. Neither is a defence of the number; both are reasons the
number does not generalise past the run.

### Where the deep tier stands

26.36 t/s at 122 B with vision and 262 k native context, on the homogeneous
plain quant, at 69.10 GiB of 108.3 GiB free. Above the ~21-22 t/s published for
this model on this silicon. It is a usable deep tier, which before this morning's
reboot could not be loaded at all.

### Harness fix

`bench.sh` guarded with `pgrep -f "curl.*\.gguf"`, which matched any shell whose
command line merely mentioned a download — including its own wrapper. It refused
to run against a leftover script that was not downloading anything but was spin-
waiting on a marker file I had renamed. Now `pgrep -x curl`, matching real
processes by name, and it prints what it found so a refusal can be diagnosed
rather than guessed at. Third instance today of `-f` matching a command line
that quotes the pattern.
