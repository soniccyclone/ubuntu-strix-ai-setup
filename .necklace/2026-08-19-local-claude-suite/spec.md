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

**Decode on the model Nathan remembers is compute-bound, not bandwidth-bound.** Qwen3.6-35B-A3B
UD-Q4_K_XL on llama.cpp b10502 Vulkan measures pp512 321.8, pp4096 255.4, tg128 25.9 t/s, with
`gpu_busy_percent` sampling `97 99 95 98 97 98 98 98 98` throughout. Published figures for
Qwen3-Coder-30B-A3B on the same silicon are 1115 pp512 / 97.7 tg128 — same active parameter count,
four times the decode. 25.9 t/s at ~1.7 GB of weights per token is about 44 GB/s of traffic, a
fifth of what this GPU pulls when it is genuinely bandwidth-limited. Saturated and slow at 44 GB/s
means the shaders are busy on something other than streaming weights, and the difference between
the two models is that three quarters of Qwen3.6's blocks are Gated DeltaNet rather than softmax
attention. **Model choice here cannot be made by picking the largest thing that fits.**

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
| Nathan at a terminal | A coding agent driving a local model with no network egress, on the backend that favours prefill, with a measured tokens/sec figure he chose the model against |
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

**Inference.** llama.cpp, kept as two independent builds — the prebuilt Vulkan release, which needs
no root and survives upgrades by re-extracting, and a ROCm build from source. Neither is the
default; each model is assigned the backend its measured numbers favour.

**Contract.** One long-lived proxy on one port, presenting both an OpenAI-shaped and an
Anthropic-shaped API over a roster of models, launching the right llama.cpp binary per model and
unloading on idle. Models are addressed by *role* — fast, deep, vision, embedding — so a frontend
names a job and the roster decides what serves it. This file is the only place a model choice
lives.

**Frontends.** opencode for code, goose for the Cowork role, OpenPencil desktop for the Design
role. Each is pointed at the contract and configured with role names. All three accept a custom
base URL against an OpenAI- or Anthropic-shaped endpoint, which was confirmed by reading their
provider code rather than their documentation.

The roster is chosen by measurement, not by parameter count, because the third finding above says
parameter count predicts the wrong thing on this hardware. Candidates are benchmarked on both
backends before any role is assigned, and the results are committed. Where a conventional-attention
model beats a newer hybrid one on decode, it wins the interactive roles regardless of benchmark
scores on paper.

The layering is the point. OpenPencil is six months old and goose is young; the proxy and llama.cpp
are not. When a frontend is replaced, the contract does not move.
