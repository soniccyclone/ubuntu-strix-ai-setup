# CUJ document: Local media generation on Strix Halo

Derived from `spec.md` in this directory. One CUJ per actor-outcome pair.

**Test convention.** Same as cycle 1: `bats-core` files at `tests/NN-<slice>.bats`, run by
`make test`. These are integration tests against running services.

**What is tested, and what is not.** No test can say whether a sprite looks good or a mesh is
worth keeping. Nathan judges that. So the tests are mechanical: does the stage run on the GPU
rather than silently on the CPU, does the output validate, is the privilege no larger than
claimed, does the timing record say what it measured.

Rigor goes where failure is **silent**. An ugly sprite announces itself; a stage that quietly
fell back to CPU, a container that quietly holds more privilege than the plan says, or a GLB
that validates by luck do not. CUJ-03 and CUJ-09 carry the weight for that reason.

**This necklace is complete when the tests pass and the pipeline is ready to hand over.** Each
CUJ carries a **UAT covers** line describing what Nathan judges afterwards. It is a handoff
note, never a gate.

---

## CUJ-01: Nathan turns a described character into a game-ready sprite

**Actor:** Nathan making 2D sprites
**Trigger:** He needs a sprite for a game and does not want to draw it.
**Journey:**
1. Nathan describes the character.
2. A sprite comes back in seconds, with a real transparent background.
3. He drops it into an engine without cutting anything out.

**Tests to create:**

| Test | Input | Assertion | Informed by |
| --- | --- | --- | --- |
| `sprite output carries real alpha` | one generated sprite | the PNG has an alpha channel and its corner pixels are fully transparent | REPL: klein + LoRA emits RGBA; the SDXL track emits an opaque field plus a baked drop shadow |
| `a sprite generates in single-digit seconds warm` | the same subject twice, weights resident | the second run completes under 15 s | REPL: 5.0 s per sprite warm, 13.3 s including LoRA load |

**UAT covers:** whether the sprites are good enough to ship in a game he cares about.

**Done when:** the two tests above pass. Both must be red when created.

**Beads:** ubuntu-strix-ai-setup-nph — closed

---

## CUJ-02: Nathan picks a sprite generator by eye

**Actor:** Nathan making 2D sprites
**Trigger:** Two candidate generators exist and he has to choose one.
**Journey:**
1. Nathan runs the same subject set through both tracks.
2. Matched pairs land side by side at identical seeds.
3. He looks at them and decides.

**Tests to create:**

| Test | Input | Assertion | Informed by |
| --- | --- | --- | --- |
| `both tracks produce the same subject set` | the subject list, run on each track | every subject exists on both tracks and the pairs share a seed | the Aug-9 method: identical subjects, the eye decides |
| `the losing track stays runnable` | the track not currently preferred | it still generates without editing any config | a comparison you cannot repeat is a decision you cannot revisit |

**UAT covers:** the verdict itself, which is his and is not encoded anywhere in this repo.

**Done when:** the two tests above pass. Both must be red when created.

**Beads:** ubuntu-strix-ai-setup-100 — closed

---

## CUJ-03: Nathan turns a described object into a textured GLB

**Actor:** Nathan making 3D assets
**Trigger:** He needs a prop and does not want to model it.
**Journey:**
1. Nathan describes the object.
2. An image is generated, then reconstructed into a textured mesh.
3. The GLB imports into an engine and looks like the thing he asked for.

**Tests to create:**

| Test | Input | Assertion | Informed by |
| --- | --- | --- | --- |
| `the mesh engine refuses to run without a GPU` | the engine started with the GPU unavailable | it fails loudly rather than falling back to CPU | the engine's own `--require-gpu`; a silent CPU fallback takes twenty minutes and looks like slowness |
| `output validates against the glTF validator` | one generated GLB | zero errors and zero warnings, with triangles, vertices and textures present | REPL: verified clean at 11,598 triangles / 3 textures; a file with the glTF magic bytes is not a valid asset |
| `the pipeline holds no CUDA and no Blender` | the running images | neither a CUDA runtime nor a Blender binary is present in any stage | the project's central claim, and the reason it runs here at all |

**UAT covers:** whether the meshes are usable in a real project rather than merely valid.

**Done when:** the three tests above pass. All must be red when created.

**Beads:** ubuntu-strix-ai-setup-eop — closed

---

## CUJ-04: Nathan gets a humanoid back rigged and moving

**Actor:** Nathan making 3D assets
**Trigger:** The asset is a character, not a prop.
**Journey:**
1. Nathan generates a humanoid mesh.
2. It comes back skinned, with conventionally-named joints and clips.
3. It plays in an engine without retargeting.

**Tests to create:**

| Test | Input | Assertion | Informed by |
| --- | --- | --- | --- |
| `the rigged file carries skin data and clips` | one rigged GLB | a skin with joints, per-vertex joint indices on the mesh, and named animation clips | REPL: 1 skin, 46 joints, `idle` and `walk`, `JOINTS_0` present |
| `joints use the conventional naming` | the same file | joint names follow the Mixamo convention the driver claims to emit | the project skips retargeting by naming joints directly; wrong names is where a walk cycle comes out backwards |
| `rigging preserves the materials the mesh arrived with` | before and after | texture count is unchanged | skinning is appended to the GLB rather than rebuilt from it, which is the project's stated reason for doing it that way |

**UAT covers:** whether the skinning holds up when the character actually moves.

**Done when:** the three tests above pass. All must be red when created.

**Depends on:** CUJ-03

**Beads:** ubuntu-strix-ai-setup-af0 — closed

---

## CUJ-05: Nathan asks for a poly budget and gets it

**Actor:** Nathan making 3D assets
**Trigger:** The asset has to fit an engine budget.
**Journey:**
1. Nathan states a face target.
2. The mesh comes back at that budget with its texture baked onto what survived.
3. He can see what choosing that budget cost him in time.

**Tests to create:**

| Test | Input | Assertion | Informed by |
| --- | --- | --- | --- |
| `a stated face target is honoured` | a target well below the default | the output's triangle count is within a small margin of the target | REPL: target 12000 produced 11,568 triangles |
| `the cost of a target is recorded, not hidden` | two runs at different targets | both timings are captured with their target alongside | REPL: target 12000 took 418.2 s against 325.1 s at the 150000 default — the cheap-sounding setting is the expensive one |

**UAT covers:** whether the budgeted meshes hold their silhouette at the poly counts he needs.

**Done when:** the two tests above pass. Both must be red when created.

**Depends on:** CUJ-03

**Beads:** ubuntu-strix-ai-setup-6pc — closed

---

## CUJ-06: Nathan generates an image from any family the box can hold

**Actor:** Nathan generating images
**Trigger:** He wants a different model than the one last used.
**Journey:**
1. Nathan names a workflow and a model family.
2. It runs against the same service, with no re-plumbing.

**Tests to create:**

| Test | Input | Assertion | Informed by |
| --- | --- | --- | --- |
| `more than one model family runs against one service` | one workflow from each of two families | both complete and write an image | REPL: Qwen-Image, FLUX.2 klein and SDXL all run in the same container |
| `a missing weight file fails by name` | a workflow naming a file that is not present | the error names the missing file rather than failing deep in a loader | REPL: workflows reference bf16 filenames while the fetch script defaults to fp8, so this mismatch is the common case |

**UAT covers:** whether the model roster covers what he actually wants to make.

**Done when:** the two tests above pass. Both must be red when created.

**Beads:** ubuntu-strix-ai-setup-f83 — closed

---

## CUJ-07: A future maintainer sees which upstream projects were patched, and why

**Actor:** Whoever administers this box six months from now
**Trigger:** An upstream release lands, or a stage breaks.
**Journey:**
1. They read what was patched and what each patch works around.
2. They can tell which patches have expired.

**Tests to create:**

| Test | Input | Assertion | Informed by |
| --- | --- | --- | --- |
| `every local patch records what it works around` | the recorded patches | each names the upstream project, the symptom, and a condition under which it stops being needed | REPL: four ports were needed for the rig layer alone, and one of them is a missing wheel for a Python version, which expires |
| `the dropped dependency is still unreachable` | the rig runtime | the modules that import it lazily are still not on the pipeline's path | REPL: `open3d` has no Python 3.13 wheel and is imported inside two functions the toolkit does not reach |

**UAT covers:** nothing. This is for whoever comes next.

**Done when:** the two tests above pass. Both must be red when created.

**Beads:** ubuntu-strix-ai-setup-gkd — closed

---

## CUJ-08: A future maintainer reproduces the timings

**Actor:** Whoever administers this box six months from now
**Trigger:** A stage looks slow, or a new model needs comparing.
**Journey:**
1. They read the timing record and see what each number measured.
2. They re-run the harness and get a comparable row.

**Tests to create:**

| Test | Input | Assertion | Informed by |
| --- | --- | --- | --- |
| `every row names model, precision, resolution and residency` | the committed record | no row is a bare duration | REPL: cold and warm differ by 3x on the image stage, so a duration without residency is meaningless |
| `the harness varies the seed between runs` | two consecutive runs of one workflow | the second run executes rather than returning a cached result | REPL: an identical graph returned in 1.0 s without executing, and that nearly became a finding |

**UAT covers:** nothing.

**Done when:** the two tests above pass. Both must be red when created.

**Beads:** ubuntu-strix-ai-setup-bd6 — closed

---

## CUJ-09: The services come back after a reboot holding no more privilege than they need

**Actor:** The machine itself
**Trigger:** A reboot.
**Journey:**
1. The machine boots and the services return without being started by hand.
2. Each holds the GPU it needs and nothing more.

**Tests to create:**

| Test | Input | Assertion | Informed by |
| --- | --- | --- | --- |
| `no media container runs privileged` | every service in the stack | none has privileged set, and each holds only the device nodes its stage requires | REPL: upstream compose asks for `privileged: true` on the rig service; it runs unprivileged here |
| `containers mount no home directory` | every service | mounts are the scoped model directories and one output directory, never `$HOME` | upstream's instructions use `toolbox`, which mounts the home directory wholesale |
| `every service answers after a reboot without manual start` | the running system | each health endpoint answers within a bounded wait | "without hand-holding" is the stated outcome |
| `the mesh stage uses the GPU, not the CPU` | one mesh run | the engine reports a Vulkan device and GPU utilisation is non-trivial during the run | a CPU fallback here is silent and merely looks like slowness |

**UAT covers:** whether it is simply there when he opens the laptop.

**Done when:** the four tests above pass. All must be red when created.

**Beads:** ubuntu-strix-ai-setup-08g — closed

---

<!--
Checks:
  All nine actor-outcome pairs have a CUJ.
  Tests are mechanical; taste is on "UAT covers" lines and never gates anything.
  Rigor concentrated in CUJ-03 and CUJ-09, where failure is silent: CPU fallback,
  invalid output, excess privilege, an unnoticed home mount.
  22 tests. Dependencies sparse: only CUJ-04 and CUJ-05 on CUJ-03.
-->
