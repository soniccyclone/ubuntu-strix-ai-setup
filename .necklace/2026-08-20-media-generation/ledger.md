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
