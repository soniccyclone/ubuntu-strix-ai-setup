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
