# Kairic Edge + opencode: a local coding agent on Strix Halo

*One subsystem of this box. Repo overview: [../README.md](../README.md).*

A working local coding-agent stack: Qwen3.8-27B with the Kairic Edge IU4
runtime, a small model beside it for compaction, and opencode wired to both.

Measured on this machine (HP ZBook Ultra G1a, Ryzen AI Max+ PRO 395, Radeon
8060S / gfx1151, 122.8 GiB unified):

| configuration | tok/s |
| --- | ---: |
| Kairic IU4, compatibility mode (**what this repo runs**) | **41.89** |
| Kairic IU4, vendor greedy fast path | 56.72 |
| ROCmFP4 + MTP, same engine family | 22.21 |
| stock Q4_K_M, upstream llama.cpp Vulkan | 12.23 |

HumanEval tasks 0–9, chat-adapted, hot cache, MTP speculation on in every arm,
matched settings. Method and every failed attempt: `../bench/results.md` and
`.necklace/2026-08-22-qwen38-27b/ledger.md`. The vendor publishes 48.78 for the
same ten-task slice; the compatibility figure reproduces their published 41.87
to within 0.05%.

Compatibility mode is what you want even though it is slower. The fast path is
~35% quicker and rejects every request carrying tool calls, temperature above
zero, grammar or logprobs — which is every request an agent makes.

## Requirements

- AMD Strix Halo (gfx1151) with unified memory. Nothing else is validated.
- 128 GB RAM. The two models hold ~61 GiB and peak around 78 GiB in use.
- ~35 GiB disk for weights, ~10 GiB for the engine image.
- Ubuntu 26.04. Podman rootless; no Docker daemon, no root at runtime.

## Setup

Two steps need root, once, and the first needs a reboot. The setup script
detects both and prints the exact commands rather than attempting them — no
process in this repo can escalate.

```
sudo cp /etc/default/grub /etc/default/grub.bak
sudo sed -i 's/^GRUB_CMDLINE_LINUX_DEFAULT="quiet splash"$/GRUB_CMDLINE_LINUX_DEFAULT="quiet splash amdgpu.gttsize=112640 ttm.pages_limit=28835840"/' /etc/default/grub
sudo update-grub
sudo usermod -aG render,video $USER
sudo reboot
```

The amdgpu driver caps GTT at half of RAM, which cannot hold 27 GiB of weights
plus a 262144-token KV cache. `gttsize` is MiB, `ttm.pages_limit` is 4 KiB
pages, and the two must agree. Rollback, verification, and what to do if it will
not boot: [privileged-steps.md](privileged-steps.md).

Then, as your normal user:

```
git clone https://github.com/soniccyclone/ubuntu-strix-ai-setup
cd ubuntu-strix-ai-setup && make kairic-setup
```

That builds the ROCm engine image, downloads and SHA-256-verifies ~30 GiB of
weights, installs the systemd unit and links the opencode config. It is
idempotent — re-running after an interrupted download resumes rather than
restarting, and it never touches a contract that is already serving.

Install opencode separately if you want the client: `npm i -g opencode-ai`.

## Daily use

```
make kairic-up      # start; first request loads the 27B, 60-90 s
opencode            # roles: contract/code, contract/compact
make kairic-down    # stop, and print the memory that came back
make status         # what is running and what it costs
```

`make kairic-up` refuses to start if under 70 GiB is free or if another contract
is already up, because two of these do not fit.

Day-to-day operation, every tuning lever, and a troubleshooting guide covering
each failure this stack actually produced: **[kairic-operations.md](kairic-operations.md)**.

## Things that are non-obvious

**Watch GTT, not RSS.** On a unified-memory APU the weights live in GTT. `ps`,
`top` and `podman stats` reported 6 GB while 91 GiB was in use. Read
`/sys/class/drm/card*/device/mem_info_gtt_total` and `mem_info_gtt_used`.

**The vendor runner is a benchmark harness, not a serving config.** Its defaults
are tuned for byte-identical reproducible runs: greedy sampling with penalties
off, reasoning disabled, one slot. Every one of those is wrong for interactive
use, and each produced a visible failure before it was fixed — a tool-calling
loop that repeated one command for an hour, empty `<think></think>` blocks, and
subagents evicting the main session's KV cache.
`config/run-kairic-serve.sh` is their runner with those four changed and
commented.

**Sampling follows Qwen's thinking-mode values** — temp 1.0, top_p 0.95, top_k
20, min_p 0, presence_penalty 0 — because reasoning is enabled. The
non-thinking set (0.7 / 0.80 / presence 1.5) is for a different mode, and a
presence penalty actively harms code, where repeating identifiers is correct.

**Two slots, 131072 context each**, not one slot at 262144. opencode's `general`
subagent runs work in parallel and inherits the main model, so with one slot
every subagent call evicts the main session and forces a full re-prefill.
Subagents are pinned to slot 1 via a second model entry aliased to the same
server model.

**`--cache-reuse` does not work here.** It has no effect on recurrent-state
models, and this is a Gated DeltaNet hybrid.

## Files this subsystem owns

Paths are from the repository root.

```
config/run-kairic-serve.sh       vendor runner, patched for serving
config/llama-swap-kairic.yaml    the two roles and their resident group
config/opencode-kairic.jsonc     client wiring: lanes, limits, compaction
harness/Containerfile.kairic     ROCm 7.2.2 + patched Composable Kernel
systemd/llama-swap-kairic.service
scripts/setup-kairic.sh          everything above, idempotent
docs/kairic-operations.md        running, tuning, troubleshooting
docs/privileged-steps.md         the root steps, with rollbacks
bench/results.md                 measurements and method
.necklace/                       the full record, including what failed
```

The engine is llama.cpp — a source snapshot published as `ciru-ai/ROCmFPX`,
branch `release/kairic-edge-qwen38-27b-v1.1`, built with a patched Composable
Kernel for the `V_WMMA_I32_16X16X16_IU4` instruction. It carries no upstream
llama.cpp history, so there is no merge path to newer llama.cpp.

Model weights are Apache 2.0 from Qwen3.8-27B. Runtime and third-party
components keep their own licenses.
