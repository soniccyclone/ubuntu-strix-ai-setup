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
