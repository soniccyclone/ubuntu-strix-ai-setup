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
