# Local media generation on Strix Halo

No ticket. Cycle 2. The agent suite is at `.necklace/2026-08-19-local-claude-suite/`
and this document assumes its findings about the machine rather than re-deriving them.

## The problem

Nathan wants game assets — 2D sprites and rigged 3D characters — generated on his own
machine. He had a ComfyUI stack working on Windows and shelved it, recording the reason in
`zoysia-windows-scratch`: the 3D tool needs `/dev/kfd`, and Docker Desktop on WSL2 exposes
only `/dev/dxg`. That blocker no longer exists. A second machine with an RX 9070 XT is on
the LAN and he has ruled it out as a dependency.

Eleven probes established what is actually true here, and three of them overturned the
assumptions this cycle opened with.

**The image stage was never slow.** `hec-ovi/text-to-3D-skill` reports 514.6 s for FLUX.2
klein at 1024 in 4 steps, and calls it out as the surprise in its own timings. The same
model, same weights, same resolution and step count, in a calibrated container measures
**29.7 s cold and 11.0 s warm** — 47x. Verified by inspecting the output rather than
trusting the clock: three 1024x1024 PNGs, correct subject, plain background. The hardware
was never the problem and neither was the model.

**The box matches its published reference.** Qwen-Image 2512 fp8 at 4 steps measures 77.7 s
cold against a published 75.4 s, and 38.3 s warm against Nathan's own Windows figure of
36.6-38.6 s. So for diffusion, Linux is *equal* to the tuned Windows stack, not better. What
Linux buys is `/dev/kfd`, which is what the 3D tool needs.

**The whole pipeline now runs, and the bottleneck moved.**

| stage | published | measured here |
| --- | ---: | ---: |
| image, 1024 | 514.6 s | 18.1 s |
| mesh, 1024, 12k faces | 345.3 s | 402.9 s |
| rig, ~12k vertices | 13.0 s | 11.2 s |
| **total** | **~14.5 min** | **7.2 min** |

Half the time, and the image stage fell from 59% of a run to 4%. The mesh stage is now
essentially the whole cost, and it is genuinely expensive rather than misconfigured. Its
timings vary widely with subject complexity — the shape flow emitted 8.3 M faces on one seed
and 10.2 M on another for the same input — and a *smaller* face target costs more, because
the work is in the decimation and it has further to go.

**Precision is a throughput decision here.** Warmed-up GEMM measures fp16 at 15.3 TFLOP/s at
n=2048, falling to 9.5 at n=8192 as operands outgrow cache, with bf16 23% behind fp16 at
matched size. Every workflow in the published benchmark set is bf16.

## Actors

- Nathan making 2D sprites for a game
- Nathan making 3D props and characters for a game
- Nathan generating images for their own sake
- Whoever administers this box six months from now, including Nathan
- The machine itself, across reboots

## Actor-outcome pairs

| Actor | Must be able to observe |
| --- | --- |
| Nathan making sprites | A described character becomes a game-ready sprite with a real transparent background, in seconds rather than minutes, without a background-removal step |
| Nathan making sprites | The same subject rendered by both candidate generators, so he can pick one by eye rather than by argument |
| Nathan making 3D assets | A described object becomes a textured GLB that a validator accepts and an engine can import, without Blender or CUDA anywhere in the path |
| Nathan making 3D assets | A described humanoid additionally comes back skinned, with conventionally-named joints and clips that play |
| Nathan making 3D assets | A stated face budget produces a mesh at that budget, with the cost of choosing it visible |
| Nathan generating images | Any of the model families this box can hold, reachable the same way, without re-plumbing per model |
| Whoever administers this | Which stages needed the upstream projects patched, what each patch works around, and how to tell if it is still needed |
| Whoever administers this | A timing record naming model, precision, resolution and whether weights were resident, and a harness that reproduces it |
| The machine | Every service back after a reboot, holding no more privilege than it needs |

## Constraints

- Diffusion runs on bare metal's GPU through containers that hold `/dev/kfd` and `/dev/dri`.
  Verified rootless and **unprivileged**, which is less than the upstream project's compose
  files ask for.
- Containers get scoped model directories, read-only where possible, and never `$HOME`. The
  upstream instructions use `toolbox`, which mounts the home directory wholesale.
- The RX 9070 XT is on the LAN and is not a dependency. Nothing may require it. The reason to
  reach for it was an 8.6-minute image stage that does not exist.
- The calibrated base image is Fedora with Python 3.13. The 3D toolkit's layers are written
  against a Debian sibling image with `uv` and a different venv path, and one of its
  dependencies publishes no wheel for 3.13.
- 110 GiB of GPU-addressable memory, from cycle 1. Nothing needs evicting, so the contention
  blowup the 3D toolkit documents does not occur here.
- bf16 is 23% slower than fp16 on this device; RADV reports no bf16 support at all for the
  Vulkan path.
- Weights already on disk: Qwen-Image, FLUX.2 klein at two precisions, SDXL, TRELLIS.2 at
  fp16, SkinTokens, and two pixel-art LoRAs.

## Approach

**One calibrated runtime, several long-lived services, HTTP between them.**

The single most valuable thing this cycle produced is a container whose numbers match a
published reference on identical work. Everything else hangs off that: when a stage is slow,
the question is whether it deviates from a known-good baseline, not whether the hardware is
disappointing. Nothing gets adopted into the pipeline until it has been measured against that
baseline in the configuration it will actually run in.

Stages stay separate processes with network seams rather than one program. The 3D toolkit
already works this way and says so deliberately, and it is what let the image stage be
diagnosed independently of the mesh stage. It also means a stage can be replaced without
disturbing its neighbours.

**Keep weights resident.** Loading is half of a cold image run and nothing here needs
evicting. Services are long-lived; the pipeline pays a load once per boot rather than once
per asset.

**Port upstream layers onto the calibrated base rather than adopt their base.** The 3D
toolkit assumes a sibling image this cycle deliberately does not use. Those patches are
carried locally, each annotated with what it works around and how to tell when it stops being
necessary — a missing wheel for a Python version is a fact with an expiry date, unlike a
design decision.

**Two sprite tracks, and the eye decides.** Both candidate generators produce the same
subject set at matched seeds; the verdict is Nathan's, by the method that produced his earlier
calls. The plan must not encode a winner, and the losing track must remain runnable so the
comparison can be repeated when either model moves.

Style is generated, never filtered. The only legitimate post-step is recovering the pixel
grid the model already composed. That principle is Nathan's, it predates this cycle, and
nothing measured here challenges it.
