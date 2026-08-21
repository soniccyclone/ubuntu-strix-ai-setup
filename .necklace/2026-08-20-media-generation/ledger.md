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

## 2026-08-20 — The 22x is answered: it was the container (probe 7)

FLUX.2 klein 4B bf16, 1024 square, 4 steps, euler/simple, cfg 1.0 — the 3D
skill's exact configuration, on its exact weights, in the calibrated toolbox
container. Minimal API graph in `repl/`, seeds varied per run:

    cold    29.7 s
    warm    11.0 s
    warm    11.1 s

Against the skill's published **514.6 s** for the same model, resolution and
step count on the same silicon:

    17.3x faster cold        47x faster warm

Verified rather than assumed, because the result was better than expected in the
same way the bogus 1.0 s warm run was: three 1024x1024 PNGs at ~1.1 MB each, and
`repl/klein-1024-4step-11s.png` is a correct brass diving helmet with round
glass ports on a plain background — the skill's own README prompt. Not noise,
not a cached stub, not an error that returned quickly.

**The hardware was never the problem and neither was the model.** Nothing about
klein is slow on gfx1151. The 514.6 s belongs to that container's configuration.
The text-encoder-reload hypothesis from probe 5 was reasonable and is not needed
to explain a 47x gap; whatever is wrong there is bigger than an eviction.

### What this does to the 3D pipeline

    stage        skill's published    measured here
    image             514.6 s            11.0 s warm
    mesh (Vulkan)     345.3 s            unchanged, not yet run
    rig                13.0 s            unchanged, not yet run

A character at 1024 was about fifteen minutes with the image stage as 60% of it.
It becomes roughly six minutes with the image stage at 3%. The bottleneck moves
to the mesh engine, which is where that project actually put its optimisation
work and where its documented 14.5% win came from.

### And the hardware question closes

Nathan said the RX 9070 XT is on the LAN but must not be depended on. It is not
needed. The reason to move diffusion to it was an 8.6-minute image stage that
does not exist. A second machine buys nothing here that eleven seconds does not
already provide.

The open item from cycle 1 — "if the gap closes, the second machine is
unnecessary" — is closed in that direction.

## 2026-08-21 — Pixel-art LoRA works, and it is the answer his own plan asked for

`Limbicnation/pixel-art-lora`, rank-64 on FLUX.2-klein-4B, ships a ComfyUI-format
LoRA (325 MB) alongside the diffusers one. At the documented settings — 512
square, 4 steps, cfg 1.0, euler, strength 1.0 — with the trigger phrasing from
its card:

    "pixel art sprite, a brave knight in shining armor holding a sword,
     game asset, transparent background, 16-bit pixel art"

    20.1 s including the LoRA load

Output kept at `repl/pixel-knight-512-lora1.0.png`. It is a real sprite:
deliberate pixels, hard edges, a silhouette that reads at sprite size, and
**genuine RGBA transparency** rather than a white field to be cut out later.

This is the thing his 08-pixel-art-plan called for and could not find. That
document's hard principle was that style must be generated and never
post-applied, that the only legal post-step is grid recovery of pixels the model
already composed, and that the way to get a specific style is a style-trained
LoRA. It then listed only SDXL candidates on Civitai, because in August nothing
existed for klein.

Two advantages over the Track S winner (SDXL + Pixel-Art-XL) that are structural
rather than aesthetic:

  - native transparency, so no background-removal stage
  - the same 4B model that serves the 3D pipeline's image stage, so one model
    and one set of weights covers both tracks

Not yet a verdict. The Aug-9 call was made by human eval on matched subjects,
and that method is the right one. This establishes only that Track F exists,
runs in 20 s, and clears the hard principle.

Caveat worth carrying into the A/B: the output is pixel-art *style* at 512, not
a 1:1 sprite grid. Grid recovery via PixelArt-Detector is still needed, exactly
as his plan specified. The pipeline he designed holds; only the generator moved.

### Container died mid-probe, exit 143

ComfyUI took a SIGTERM 13 minutes in, with 108 GiB free, so not OOM. Cause
unidentified. Its log confirms the probe-7 numbers independently — prompt
execution of 28.71 s, then 10.50 s, then 10.67 s — so nothing measured is in
doubt. Restarted with `--restart=unless-stopped`. If it recurs, find the sender
rather than restarting again.

## 2026-08-21 — TRELLIS.2 mesh engine, setup notes

The engine is the interesting half now that the image stage is 3% of a run.
Its compose service asks for `/dev/dri` only — no `/dev/kfd`, no ROCm — which
confirms the Vulkan-only claim, and `group_add 990/44`, which happen to be this
box's real `render` and `video` gids. `--require-gpu` makes it refuse to fall
back to CPU rather than quietly taking twenty minutes.

Its isolation shape matches what cycle 1 settled on: models mounted read-only,
one output directory writable, nothing else.

Two setup traps, both mine:

**`gh repo clone` does not fetch submodules.** The build died at
`add_subdirectory: /src/thirdparty/ggml does not contain a CMakeLists.txt`.
The dependency is `pwilkin/ggml` on a `trellis-patches` branch — a fork of ggml
carrying the TRELLIS kernels — wired in at
`layers/image2mesh/engine/thirdparty/ggml`. `git submodule update --init
--recursive` fixes it.

**Then I checked the wrong path** and reported it still missing, because the
submodule sits under `engine/` while CMake sees it at `/src/thirdparty/ggml`
after the Dockerfile's COPY. The build was fine; my verification was not.

Weights are `ilintar/trellis2-gguf`, which publishes three precisions:

    root (fp16)    16.49 GB across ten files
    q8             10.03 GB
    q4              6.55 GB

Fetching the fp16 root set, since that is what the skill's published 345.3 s
mesh timing used and the point is to reproduce it before improving on it. Given
cycle 1 measured a 2.24x swing between quantisations of one model, and probe 4
measured fp16 beating bf16 by 23% here, the q8 and q4 sets are worth measuring
afterwards rather than assumed to be slower or faster.

## 2026-08-21 — Mesh stage runs, and it is now the whole cost (probe 8)

Engine up on Vulkan — `vulkan: Radeon 8060S Graphics (RADV STRIX_HALO)` — with
`/dev/dri` only and no ROCm. Input was the klein diving helmet from probe 7, so
the subject matches the 3D skill's own README example.

    res 512, default target, cold                271.8 s
    res 512, default target, warm                315.1 s
    res 512, default target, ComfyUI stopped     325.1 s
    res 512, target_faces=12000                  418.2 s

Published figure for res 512, default target, weights resident: **154.2 s**.

### Three things these runs settle

**Weight loading is not the variable.** Warm was slower than cold. Unlike the
image stage, where load was half of a cold run, the 16 GB of GGUF here costs
little relative to the compute.

**Contention is not the variable on this box.** ComfyUI was holding 19.3 GiB;
stopping it moved GTT from 19.3 to 4.2 GiB and the run got *slower*, 315.1 to
325.1 s. The skill documents a 345 s to 1084 s blowup from exactly this, so it
is real on their hardware. With the ceiling at 110 GiB there is nothing to
contend for here, which is a direct dividend of the cycle-1 GTT change.

**A smaller face target costs more, not less.** target 12000 took 418.2 s
against 325.1 s at the 150000 default, because the work is in the QEM decimation
and it has further to go. Their guidance recommends 2K-6K for a prop, so the
cheap-sounding setting is the expensive one.

Run-to-run variance is large and traceable: the shape flow emitted 8,312,940
faces on one seed and 10,262,608 on another for the same image. Everything
downstream scales with that.

### Why this is probably not a fair comparison

Their 154.2 s row does not name its subject. Mine is a photorealistic brass
helmet with three glass ports and a dozen fittings, generated at 1024; their
image row used a ceramic teapot. Geometric complexity drives voxel count, which
drives every stage after it. Matching subjects would be needed to call this a
regression rather than a difference, and it is not worth the hours: the number
that matters is the total, and the total improved.

### The pipeline works end to end

    scripts/validate-glb.mjs helmet12k.glb
    0 errors, 0 warnings, 0 infos
    generator trellis.cpp v1.0.0, glTF 2.0, EXT_texture_webp
    11568 triangles, 10997 vertices, 3 textures

Kept at `repl/helmet-12k.glb`. Clean against the Khronos validator, which is
what the project claims and now demonstrably delivers on this machine.

    stage      skill published    measured here
    image           514.6 s          11.0 s
    mesh            154.2 s       271.8 - 418.2 s
    total         ~669 s (11 min)  ~283 - 429 s (4.7 - 7.2 min)

The mesh stage is slower here and the total is still roughly halved, because the
image stage collapsed by 47x. The bottleneck has moved from a stage that was
misconfigured to a stage that is genuinely expensive, which is the honest place
for it to be.

## 2026-08-21 — Pixel-art A/B generated, verdict withheld (probe 9)

Matched subject set — knight, elven archer, orc warrior, treasure chest — same
seed, both tracks, via `repl/pixel_ab.py`. Pairs kept in `repl/pixel-ab/`.

    track                                  per sprite
    F  klein 4B + Limbicnation LoRA          5.0 s   512, 4 steps, cfg 1.0
    S  SDXL + nerijs/pixel-art-xl            8.0 s   1024, 8 steps, cfg 2.0

**Track F is faster**, which inverts the Aug-9 result. That verdict had SDXL
beating Qwen-Image on speed because SDXL is 2.6 B against Qwen's 20 B. Track F
is a 4 B model at 4 steps, so the parameter gap no longer buys SDXL anything.

Observable differences, stated as description rather than judgement:

  - Track F emits RGBA with real transparency. Track S emits an opaque field
    plus a baked drop shadow, so it needs a background-removal stage that Track
    F does not.
  - Track F fills the 512 frame. Track S places a smaller sprite inside 1024,
    so the effective sprite resolution is lower than the file size suggests.
  - Track F holds higher contrast and a cleaner silhouette at sprite size;
    Track S detail blends together, and the axe in the orc is hard to read.

**The verdict is Nathan's and is not recorded here.** The Aug-9 method was human
eval on matched subjects and that method still stands. What this probe
establishes is that the pair exists, both run in single-digit seconds, and Track
F clears the hard principle that style must be generated rather than filtered.

One reason to distrust a quick read in Track F's favour: the Track S settings
are mine, not his. Eight steps at cfg 2.0 with euler_ancestral at 1024 is a
reasonable default and it is not necessarily what produced his Aug-9 result. A
tuned Track S may close much of the visible gap, and losing to an undertuned
opponent is not winning.

## 2026-08-21 — Humanoid meshed; the rig layer needed porting (probe 10)

Character reference generated with klein at 1024 in **18.1 s** — full body,
near-T-pose, plain background, which is what the reconstruction wants. Kept at
`repl/warrior-1024.png`. It carries a garbled hallucinated watermark in the
bottom-left corner, harmless for meshing and worth knowing klein does that.

    res 1024, target_faces 12000        402.9 s
    skill published, same settings      345.3 s

1.17x, far closer than the 512 comparison. That supports the probe-8 reading
that the 512 gap was subject complexity rather than a regression: a humanoid in
plate armour is closer in geometric complexity to whatever they measured than a
brass helmet with three glass ports was.

### The rig layer does not build against this base, and the reasons stack

Its Dockerfile is `FROM comfyui-strix-halo:latest`, the sibling
`comfyui-strix-docker` image, which this cycle deliberately does not use — the
kyuz0 toolbox is the calibrated one. Tagging the toolbox under that name gets
past the FROM and straight into three incompatibilities:

    apt-get                  the toolbox is Fedora; dnf and microdnf, no apt
    /app/.venv/bin/python    the toolbox venv is /opt/venv
    uv                       not installed in the toolbox

All three are mechanical. Patched: `dnf install` with Fedora package names
(`mesa-libGL glib2 libgomp`), `/opt/venv/bin/python -m pip`, and an explicit
interpreter in the ENTRYPOINT.

### Two mistakes of mine in that sequence

**A status marker that lied.** The first rig build wrote `echo DONE` with a
`;` rather than `&&`, so the marker appeared whether the build succeeded or not,
and I went on to run a container from an image that did not exist. This is the
same guarantee I built into cycle 1's `fetch-122b.sh` on purpose and then did
not carry over. Markers now reflect the exit code.

**A blind sed.** Rewriting `--python /app/.venv/bin/python` to point at the new
venv left uv's flag behind as a positional argument to pip, so the build tried
to install the interpreter as a package. The flag and its value had to go
together. Redone from a saved copy of the original rather than patched further.

## 2026-08-21 — Full text-to-3D pipeline runs end to end (probe 11)

Rig service up **unprivileged**. Their compose asks for `privileged: true`; it is
not needed here — `--device=/dev/kfd --device=/dev/dri --group-add keep-groups`
is sufficient, as probe 3 established. Startup log:

    [rig] model loaded in 4.1s, attention sdpa
    [rig] device AMD Radeon 8060S Graphics
    {"ready": true}

"attention sdpa" is their flash-attn shim doing its job: SkinTokens imports
`flash_attn_interface` with no fallback, and the container supplies a stand-in
backed by torch SDPA rather than editing upstream.

    rig, 12,732 vertices        11.2 s
    skill published, ~11k       13.0 s

Output validates clean, 34 Mixamo-named joints, `idle` and `walk` clips.

### The whole pipeline, measured on this machine

    stage                         published        here
    image, 1024                     514.6 s        18.1 s
    mesh, 1024, 12k faces           345.3 s       402.9 s
    rig, ~12k vertices               13.0 s        11.2 s
    total                         ~872 s (14.5m)  432 s (7.2m)

Half the time, on a laptop, with no CUDA, no Blender and no second machine.
The image stage went from 59% of the run to 4%.

### Three ports the rig layer needed, none of them subtle

The layer is written against the sibling `comfyui-strix-docker` image. Against
the kyuz0 toolbox, which is the one this cycle calibrated, three things break:
`apt-get` (Fedora has dnf), `/app/.venv` (this base uses `/opt/venv`), and `uv`
(absent). All mechanical.

The fourth is not mechanical: **`open3d` publishes no wheel for Python 3.13**,
which this base ships. It is imported lazily in exactly two SkinTokens
functions, `parser/bpy.py` and `info/asset.py`, and the toolkit reaches neither
because it feeds meshes through the npz loader rather than bpy. Omitting it
builds and rigs correctly. If some path ever reaches it the ImportError will
name the file, which is a better failure than not building.

That is the same manoeuvre the toolkit already performs for flash-attn and bpy:
read the source, find that the blocker is packaging rather than computation, and
route around it without forking upstream.

## 2026-08-21 — spec.md and cuj.md written

Eleven probes in, the research is done: every stage of the pipeline has been run on this
machine and every claim in the spec is a measurement rather than a citation.

`spec.md` at roughly two pages, nine actor-outcome pairs. `cuj.md` with nine CUJs and 22
mechanical tests, following the cycle-1 structure — taste on **UAT covers** lines that gate
nothing, and rigor concentrated where failure is silent.

For this cycle, silent means four things specifically:

  - a stage falling back to CPU, which merely looks like slowness
  - a GLB that carries the glTF magic bytes but is not a usable asset
  - a container holding more privilege than the plan claims
  - a home directory mounted somewhere nobody looked

CUJ-03 and CUJ-09 carry those. Everything else gets a smoke test.

Three test rows exist only because a probe went wrong first:

  - the harness must vary the seed, because an identical graph returned in 1.0 s without
    executing and that nearly became a finding
  - every timing row must state residency, because cold and warm differ by 3x on the image
    stage
  - a missing weight must fail by name, because the published workflows reference bf16
    filenames while the fetch script defaults to fp8, making that mismatch the common case

The pixel-art verdict is deliberately absent from both documents. CUJ-02 requires only that
both tracks produce matched pairs and that the losing track stays runnable, which is what
makes the comparison repeatable when either model moves. Encoding a winner would be encoding
my taste, and the whole reason that CUJ exists is that mine is not the one that counts.

## 2026-08-21 — CORRECTION: the sprites have no alpha channel (probe 12)

I said twice, and told Nathan twice, that the pixel-art LoRA produces "genuine
RGBA transparency". **It does not.** Every sprite produced in probes 9 and 10 is
PNG colour type **2** — RGB, three channels, no alpha:

    pixel-knight-512-lora1.0.png    color_type=2  corner_alpha=None
    pixel-ab/klein-orc.png          color_type=2  corner_alpha=None
    pixel-ab/sdxl-orc.png           color_type=2  corner_alpha=None

What looked like transparency is the model **painting a checkerboard**, because
that is how transparency is displayed in the images it trained on. It renders
the *convention for* transparency as if it were the subject.

### Why I believed it

The LoRA's model card states "**512x512 RGBA** output with transparent
backgrounds". The picture matched the claim, so I repeated the claim. I did not
check the file. A rendered checkerboard and real alpha are visually identical
in every viewer, which is precisely why looking was never going to settle it.

### It is not achievable through this path at all

`VAEDecode` returns `IMAGE` — three channels. The Flux VAE cannot emit alpha.
ComfyUI ships `JoinImageWithAlpha`, `ImageToMask` and `SplitImageWithAlpha`,
which exist because alpha has to be **constructed** downstream, never generated
by the sampler. So the card overclaims for any standard workflow.

### What this costs the plan

The structural argument I made for Track F was native transparency and therefore
no background-removal stage. **That advantage does not exist.** Both tracks need
background removal, and Track F's output is arguably the harder of the two to
key: a flat field is trivial to remove, a painted checkerboard is not.

Track F's remaining advantages are real and unchanged — 5.0 s against 8.0 s, and
one 4B model shared with the 3D pipeline's image stage. The transparency claim
is withdrawn.

### The discipline that caught it

A mechanical test written for CUJ-01 — assert colour type 6 and a transparent
corner pixel — failed on the first run and produced this. The eye could not have
caught it and neither could a benchmark. It is the clearest case so far for
tests that check a fact rather than an impression, and it landed on a claim I
had already stated confidently to the user.

## 2026-08-21 — Background keying, built because the plan had assumed it away

Correcting the alpha claim left a real gap: sprites need transparency and
nothing in the pipeline produced it. Two routes existed.

**The ComfyUI node route did not survive contact.** `ImageColorToMask` +
`JoinImageWithAlpha` produced a uniform mask — everything transparent with an
invert, everything opaque without. The reason was visible only by looking at the
image: asked for "solid magenta", the model paints a deep pink near #E8146E, not
#FF00FF, so an exact colour match found nothing. I had been reasoning about
node semantics when the input was the problem.

**The deterministic route works and is `tools/key_bg.py`.** Sample the corner
colour, flood fill inward from the border with a tolerance, write RGBA. Stdlib
only, no model, no network, ~3 s end to end including generation.

    512x512   transparent 209958/262144 = 80.1%   color_type=6  corner_alpha=0

Flood fill from the edges rather than a global colour test, because a sprite may
legitimately contain the background colour — a pink gem, a red cape — and a
global test punches holes in it. The cost is visible in the output: a small pink
cluster survives at the knight's hip, background colour enclosed by the
silhouette where the fill cannot reach. That is the right trade and it is a
known residue rather than a surprise.

This also satisfies the hard principle rather than bending it. Keying adds no
pixels and changes no colours; it recovers the field the prompt asked for. It is
the "grid recovery" class of post-step, not a style filter.

### The prompt changed too

"transparent background" is what produced painted checkerboards, so both tracks
now ask for a plain solid magenta field. That is a keyable input by
construction, and it is why the A/B remains fair: both tracks get the same
treatment.

### Five tests, and one of them exists to pin a mistake

`tests/m01-sprite.bats` asserts that the **raw** generator output is colour type
2 — no alpha. That looks like testing a defect, and it is deliberate: the claim
that these models emit RGBA is plausible, is printed on the model card, and is
wrong. If a future model does emit alpha, that test fails, which is the correct
way to be told.

## 2026-08-21 — Beads worked to completion

All nine CUJs closed. Bead IDs written into `cuj.md`.

A label collision the skill could not know about: cycle 1 already used
`cuj:CUJ-01`-style labels in this repo, so these carry a second
`necklace:2026-08-20-media-generation` label to keep the two cycles separable.

### Things the implementation forced that the CUJ document did not anticipate

**Background keying became a stage.** The document assumed the sprite tracks
emitted transparency. They do not, and `tools/key_bg.py` exists because of it.
CUJ-01's outcome was rewritten from "without a background-removal step" to
"with a known background-removal step rather than an assumed one".

**A test now pins a defect on purpose.** `tests/m01-sprite.bats` asserts the raw
generator output is PNG colour type 2 — no alpha. That reads as testing a bug,
and it is deliberate: the claim that these models emit RGBA is plausible,
printed on the model card, and wrong. If a future model does emit alpha the test
fails, which is how the fact should surface.

**The harness had to learn to explain rejections.** CUJ-06 asked that a missing
weight fail by name. It did not: `urllib` raised a bare `HTTPError` and printed
a stack trace, which is the failure mode the CUJ was written to prevent. The
service says "Value not in list unet_name" and the caller holds the graph, so
the two together now produce

    REJECTED by the service: Prompt outputs failed validation.
    Value not in list -- UNETLoader.unet_name = "definitely-not-here.safetensors" is not available

That test also needed a *valid* fixture graph. The first attempt wired a MODEL
into SaveImage, and type validation rejected it before the weight lookup ran, so
the test passed on the wrong error.

**Two test-authoring mistakes worth the same note as any other.** A `${VAR:?...}`
message containing an apostrophe broke `tools/rig.sh` with an unmatched-quote
error, and `podman inspect .HostConfig.Devices` is empty under rootless podman,
so device passthrough has to be asserted from inside the container rather than
from its config. Both are the same lesson as cycle 1's bind-mount test: check
the running system, not the declaration that was supposed to produce it.

## 2026-08-21 — Services left running twice; made structural instead of promised

Nathan twice found GPU services running that I had started and forgotten. Same
pattern both times: start services to verify something, prove the thing, write
up the result, leave the services holding the GPU. The verification was right;
the cleanup was a thing I intended to remember and did not.

"I will remember" is not a fix, so:

  - `make asset`, `make sprite` and `make rig` now depend on `media-up` and
    carry `trap '$(MAKE) media-down' EXIT`. They start what they need and stop
    it again whether they succeed, fail or are interrupted.
  - `make status` reports GPU busy, GPU memory, containers, every unit's state,
    and stray `serve.py` / `pipeline.py` helpers.
  - `make stop-all` stops everything this repo can start and then runs `status`,
    so the claim is proven rather than asserted.
  - `make viewer` stays foreground; it is interactive and uses no GPU.

Verified by running `make sprite` three times and checking the GPU fell back to
0% after each, rather than by reading the Makefile and believing it.

### A false "failed" that would have hidden a real one

After the first fix the units ended every clean stop in `failed`, because
`systemctl stop` sends SIGTERM, ComfyUI does not handle it, and podman escalates
to SIGKILL — exit 137. A first attempt guessed 143 (SIGTERM) from habit and did
not work; the actual code was in `systemctl status`, which I should have read
before editing. `SuccessExitStatus=143 137 SIGTERM SIGKILL` fixes it.

Worth more than tidiness: a unit that is always `failed` after a normal stop
makes a genuine failure invisible, because both look identical.

### Also left undone until asked

The toolkit ships a one-command pipeline and a three.js viewer, and I had used
neither — every stage was driven directly through its HTTP API to measure it.
That is fine for measurement and useless as a handoff. Nathan asked how to turn
on the UI from the project's own screenshots, and the answer was a layer I had
never started. `make asset` and `make viewer` now cover it, both verified end to
end: prompt to textured GLB in 7m33s, viewer serving the gallery on :8190.

## 2026-08-21 — Recording how `warrior-1024.png` was actually made

Nathan liked that image and asked for the exact command. **It was not in the
ledger.** Probe 10 recorded that a character reference was "generated with klein
at 1024 in 18.1 s" and nothing about how — no prompt, no sampler settings, no
seed. An image good enough to want again, with no way to get it again.

Recovered from the session and committed as `repl/warrior-1024.json`, which is
the graph itself rather than a prose description of it.

    model        flux-2-klein-4b.safetensors        (bf16, no LoRA)
    text encoder qwen_3_4b.safetensors              (type flux2)
    vae          flux2-vae.safetensors
    size         1024 x 1024
    sampler      euler / simple, 4 steps, cfg 1.0, denoise 1.0
    seed         100000
    negative     empty

    positive     a female warrior in polished steel plate armour, full body,
                 standing straight, arms slightly away from body, T-pose,
                 front view, plain white background, game character reference sheet

    run          python3 tools/imgbench.py \
                   .necklace/2026-08-20-media-generation/repl/warrior-1024.json --runs 1

### The seed in the original file was a lie

The graph I wrote at the time declared `"seed": 777001`. That value never
reached the sampler: `imgbench.py`'s `reseed()` rewrites every seed input to
`100000 + run_index` before queueing, so the run used **100000**. Recording
777001 would have produced a record that looks precise and reproduces a
different image — worse than recording nothing, because it would be trusted.

The reseeding exists for a good reason (an identical graph returns a cached
result in ~1 s and nearly became a finding), but it makes the seed written in a
graph file advisory rather than authoritative. Anything using that harness must
read the seed from the harness, not from the file.

### What made the image work, for reuse on other characters

The prompt is doing three separate jobs and it is worth keeping them separate
when adapting it:

  - the subject
  - the pose: "full body, standing straight, arms slightly away from body,
    T-pose, front view" — reconstruction needs limbs separated from the torso
    and a front-on view
  - the plate: "plain white background, game character reference sheet" — a
    clean field the mesh stage can cut against

Known artefact: klein renders a garbled hallucinated watermark in the
bottom-left corner. Harmless for meshing, and it is cropped out of nothing, so
expect it to reappear.

### Rule this establishes

Any artefact kept in `repl/` because it is good must have its generating inputs
kept beside it. A picture without its prompt is a souvenir, not a result.

## 2026-08-21 — UAT round 1: Nathan's verdicts and one real defect

### Pixel-art A/B: Track F wins

Nathan, on the matched pairs: "ALL the SDXL ones SUCK." That is the verdict the
Aug-9 method was for, and it settles CUJ-02. `klein 4B + Limbicnation LoRA` is
the sprite track; `SDXL + nerijs/pixel-art-xl` is shelved but stays runnable, as
the CUJ requires, so the comparison can be repeated when either model moves.

Worth recording that the timing argument reversed too: Track F is 5.0 s against
Track S's 8.0 s, where the Aug-9 verdict had SDXL winning on speed against a
20 B Qwen-Image. A 4 B model at 4 steps removed that advantage.

### `make character` produced an unriggable mesh, and the prompt was mine

    make character SUBJ="an orc shaman with bone jewelry and a gnarled staff"
    -> mesh 246.1 s
    -> NOT_A_CHARACTER: the predicted skeleton is not a humanoid
       "nothing above the root, so this is not a standing figure"

Nathan's read was that the reference was not a T-pose. Looking at the image, the
pose is fine — full body, front view, arms clear of the torso. The reference
contains **three subjects**: the orc, a staff spanning a third of the frame, and
a floating head vignette in the top-left corner.

The vignette is caused by my own plate text, `"game character reference sheet"`.
That phrase invites the conventions of a reference sheet: callout busts,
multiple views, prop breakouts. It survived the warrior because that subject
happened to render as one figure. TRELLIS reconstructs **one volume from one
image**, so every extra disconnected subject corrupts the result and the rig
correctly refuses what comes out.

Plate replaced with `"single figure alone, centred, isolated on a plain white
background, no text, no logo, no additional views, no inset portraits"`.

### The expensive part was finding out four minutes late

The rig knew within seconds. The pipeline spent 246 s meshing something that
could never rig. `tools/refcheck.py` now answers the same question from the
reference alone, in about a second, by flood-filling the background from the
border and counting what is left:

    orc      2 subjects   [0] 24.7% figure   [1] 0.4% bbox=[148,32,208,132]
    warrior  1 subject    [0] 17.1%

`make character` runs it between the image and mesh stages and stops with a
re-roll suggestion rather than proceeding.

**Known limitation, stated rather than discovered later:** the check finds
*disconnected* subjects. The staff touches the orc's hand, so it merges into
blob 0 and passes. A held prop that leaves the silhouette while staying
connected is still a reconstruction problem and this will not catch it — the
bbox widening to 900 px is the only hint. Subjects for reconstruction should
avoid held props regardless.

### Deferred by Nathan

opencode UAT is deferred; seeing the contract answer is enough to close CUJ-01
for now. He is not running the 25-minute suite.

## 2026-08-21 — Reference resolution decides whether a mesh is usable (probe 13)

A clean single-subject T-pose orc reference produced a garbled mesh the rig
refused. `refcheck` passed it, correctly — it was one connected subject on a
clean plate. Nathan checked the image and said so, and he was right.

The variable was pixels on the subject:

    orc      512   278x472 = 131k px   garbled, NOT_A_CHARACTER
    warrior 1024   442x948 = 419k px   rigged, 46 joints
    orc     1024   526x964 = 507k px   rigged, 44 joints, validator clean

The third row is a **controlled test**: same prompt, same seed, same subject as
the failure, only `IMGSIZE` changed. TRELLIS builds shape from image features
and a 278-pixel-wide figure does not carry enough of them.

`refcheck` now warns below 250k subject pixels. That number is an interpolation
between one failure and two successes, not a measured boundary, so it warns and
does not reject.

### The cause was my own variable name

`RES` was doing double duty — the reference image size in `ref` and `character`,
and the TRELLIS voxel grid in `asset` and `mesh`. `make ref` therefore produced
a 512 px reference while `RES` was documented as a mesh setting. Split into
`IMGSIZE` (image pixels) and `RES` (voxel grid), both defaulting to 1024.

This is the second defect from that collision. The first was the multi-subject
orc; this was the small-subject orc. One overloaded name, two failures that
looked like different problems and cost about fifteen minutes of meshing each.

### Open, not explained

The rigged orc carries `["idle"]` where the warrior carried `["idle", "walk"]`,
and has 44 joints against 46. Unknown whether the walk solver declined a
skeleton it could not use, or something about the subject's leg structure. Not
investigated; flagged for Nathan to judge in the viewer, since whether it
matters depends on what he does with it.
