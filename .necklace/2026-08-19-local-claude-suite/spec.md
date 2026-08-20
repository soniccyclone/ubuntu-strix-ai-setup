# A local Claude suite on Strix Halo

No ticket. ZOYSIA — AMD Ryzen AI MAX+ PRO 395, 122 GiB unified, Ubuntu 26.04, kernel 7.0.0-29.

## The problem

Nathan wants the shape of the Claude suite — Code, Cowork, Design — running on open models on his
own hardware. He already knows the opencode leg. The other two legs, and the thing that feeds all
three, are unmapped.

The box is a clean slate: no ollama, llama.cpp, vLLM, opencode, uv, docker, or huggingface CLI.
That is an advantage, because four measurements taken today rule out most of the obvious plans.

**GTT caps the machine at half its memory.** `mem_info_gtt_total` reads 61.41 GiB against 122 GiB
installed; `mem_info_vram_total` is 512 MiB and already consumed by the framebuffer, so every byte
of weights lands in GTT. RADV reports the same ceiling: `Vulkan0: ... (63395 MiB, 56235 MiB free)`.
A 122B-A10B at Q4 wants ~70 GB and does not fit until that moves, which is a boot argument, which
is a reboot.

**Unified memory does not make CPU offload free.** `repl/membw.c` measures 75.9 / 85.1 / 79.4 GB/s
from 16 Zen 5 cores against a bus rated near 256 GB/s. The cores cannot saturate the controller;
the iGPU gets far closer. Any layer that lands on CPU runs at roughly a third of the available
bandwidth, so partial offload is a proportional loss rather than a rounding error.

**Decode is compute-bound, and nothing on a model card predicts what it costs.** Six runs on
llama.cpp b10502 Vulkan, same binary and flags, `gpu_busy_percent` at 95-98% throughout each. Full
matrix in `repl/results.md`:

| Model | Attention | Packager | Quant | Size | pp512 | tg128 |
| --- | --- | --- | --- | ---: | ---: | ---: |
| Qwen3.6-35B-A3B | hybrid DeltaNet | bartowski | Q4_K_M plain | 20.74 GiB | 707 | 58.0 |
| Qwen3.6-35B-A3B | hybrid DeltaNet | unsloth | Q8_0 plain | 34.36 GiB | 705 | 46.3 |
| Qwen3.6-35B-A3B | hybrid DeltaNet | unsloth | UD-Q6_K_XL dyn | 29.65 GiB | 641 | 46.6 |
| Qwen3.6-35B-A3B | hybrid DeltaNet | unsloth | UD-Q4_K_XL dyn | 20.81 GiB | 322 | 25.9 |
| Qwen3-Coder-30B-A3B | conventional | unsloth | UD-Q4_K_XL dyn | 16.45 GiB | 774 | 78.6 |
| Qwen3-Coder-30B-A3B | conventional | lmstudio | Q4_K_M plain | 17.35 GiB | 770 | 70.5 |

Three variables, and they do not compose independently. Quantiser packaging is the sharpest: the
same Ultra Dynamic scheme is 2.24x **slower** than a plain quant on the DeltaNet model and 1.12x
**faster** on the conventional one. Same packager, same quant level, opposite sign — it substitutes
IQ-family types on selected tensors, which is a small win on conventional attention and lands on
catastrophic RADV kernels in the linear-attention path. Compared fairly, plain against plain,
architecture costs only 1.21x on decode. Quant level is sub-linear: 66% more bytes per token buys a
20% slowdown, so above roughly Q6 size is nearly free.

The conventional model at 70-79 t/s brackets the published 97.7 for the same model at Q4_K_S on this
silicon, which rules out anything systemic throttling the box.

**Model choice here means choosing a file — that model, that quant, that packager, that backend —
and the only way to know is to run it.**

**The two backends win different halves of the workload.** Published gfx1151 numbers put Vulkan
ahead on decode by roughly a third and ROCm ahead on prefill by roughly a fifth. Agentic coding is
prefill-heavy — large contexts re-read every turn; interactive chat and design work are
decode-bound.

## Actors

- Nathan at a terminal, writing code
- Nathan in a GUI, working on files and documents without a terminal
- Nathan designing something visual
- Whoever administers this box six months from now, including Nathan
- The machine itself, across reboots

## Actor-outcome pairs

| Actor | Must be able to observe |
| --- | --- |
| Nathan at a terminal | A coding agent driving a local model with no network egress, against a model whose throughput he has seen measured on this machine |
| Nathan in a GUI | A desktop agent that reads and writes files in a folder he nominates, asks before destructive actions, and runs on the same local endpoint with no separate model configuration |
| Nathan designing | A desktop design tool whose AI is pointed at the same local endpoint, that can take a described design to an editable document and export it as JSX or HTML, and take HTML back the other way |
| Nathan, any leg | Switching which model backs a role by editing one file, with no frontend reconfigured and no service reinstalled |
| Nathan, any leg | A model that accepts an image, reachable from whichever frontend needs it |
| Whoever administers this | A benchmark record in the repo that says what was measured, on which build, with GPU utilisation beside each number, and a harness that reproduces it |
| Whoever administers this | Every root-requiring step written down as a command with its justification, separable from everything installed under `$HOME` |
| The machine | The stack back up after a reboot without hand-holding, with the memory ceiling it was configured for |

## Constraints

- GTT is 61.41 GiB of 122 GiB installed. Raising it is a kernel boot argument and a reboot. Nathan
  has chosen to do this early rather than defer it.
- Agent sessions cannot escalate: `sudo -n` fails. Every root step is handed over as a command,
  never executed on his behalf.
- RADV on this device reports `bf16: 0` with `fp16: 1`, `int dot: 1`, `KHR_coopmat`. BF16 GGUFs are
  unusable; fp16 and the integer-dot quant kernels are the fast paths.
- `/dev/kfd` is `root render` and Nathan is not in `render`. Any ROCm path is blocked on a group
  change and a re-login before it is blocked on anything technical.
- Ubuntu 26.04 is not an AMD-supported ROCm target. Universe carries 7.1.1; AMD's own repository
  targets noble. The ROCm leg is unsupported ground by construction.
- llama.cpp publishes no prebuilt ROCm binary. That leg is a source build, on every upgrade.
- 122 GiB total, minus desktop. A large tier and a fast tier cannot both be resident; residency has
  to be scheduled rather than assumed.
- Wayland/GNOME session. Tauri v2 desktop apps need `libwebkit2gtk-4.1`, which is present.

## Approach

**Replicate the contract, not the three products.** Anthropic's own documentation says Cowork runs
the same agentic architecture as Claude Code, and that Design hands work to Claude Code. The suite
is three frontends over one agent loop reached through one API. Build that API locally and hang
frontends off it.

Four layers, each replaceable without disturbing the others:

**Machine.** Raise the GTT ceiling toward the installed memory, put Nathan in `render`, one reboot.
Everything downstream assumes the raised ceiling.

**Inference.** llama.cpp on the prebuilt Vulkan release — no root, and upgrades are a re-extract.
One backend, not two. ROCm wins prefill by roughly a fifth on paper and costs a source build on
every upgrade, on a distribution AMD does not target; that trade is not worth making before anything
is running. It is deferred to a comparison after the suite works, and the trigger for running it is
Nathan finding the latency unacceptable in use rather than a number looking improvable.

**Contract.** One long-lived proxy on one port, presenting both an OpenAI-shaped and an
Anthropic-shaped API over a roster of models, launching the right llama.cpp binary per model and
unloading on idle. Models are addressed by *role* — fast, deep, vision, embedding — so a frontend
names a job and the roster decides what serves it. This file is the only place a model choice
lives.

**Frontends.** opencode for code, goose for the Cowork role, OpenPencil desktop for the Design
role. Each is pointed at the contract and configured with role names. All three accept a custom
base URL against an OpenAI- or Anthropic-shaped endpoint, which was confirmed by reading their
provider code rather than their documentation.

The roster is chosen by measuring files, not by reading model cards, because every quantity
normally used to choose — parameter count, file size, quant level, benchmark score — pointed the
wrong direction at least once during this investigation. A candidate earns a role by being run in
the configuration it would actually be served in, and its numbers are committed beside the config
that names it. The measurement is not a precaution taken before a decision already made; it is the
decision, and three of the conclusions reached on the way to this document were overturned by the
next run.

Throughput is a floor, not the ranking. Once a candidate clears the interactive threshold, capability
decides the role — a model that decodes 20% slower but carries vision, a long context, and stronger
reasoning takes the seat over a faster one that carries none of them.

The layering is the point. OpenPencil is six months old and goose is young; the proxy and llama.cpp
are not. When a frontend is replaced, the contract does not move.
