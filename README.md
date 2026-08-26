# Agentic AI on a Strix Halo box

Everything needed to run coding agents, chat models and media generation
locally on an AMD Strix Halo APU — no cloud, no API keys, no daemon running as
root.

The machine this was built and measured on: HP ZBook Ultra G1a, Ryzen AI Max+
PRO 395, Radeon 8060S (RDNA 3.5, `gfx1151`), 122.8 GiB unified memory, Ubuntu
26.04. Every number in this repository was measured on it, and the method is
published beside each one.

## Subsystems

### Coding agent — Qwen3.8-27B Kairic Edge + opencode

The daily driver. A 27B model with a hardware-native IU4 compute lane,
multi-token speculation, and a second small model beside it that handles
context compaction without evicting your session.

    41.89 tok/s   what this repo runs (tool calls, sampling, thinking all work)
    22.21 tok/s   the same model on the next-best local runtime
    12.23 tok/s   the same model on upstream llama.cpp

**[docs/kairic-edge-opencode.md](docs/kairic-edge-opencode.md)** — setup from a
fresh machine, in one command.
**[docs/kairic-operations.md](docs/kairic-operations.md)** — running, tuning,
and troubleshooting by symptom.

```
make kairic-setup    # once: image, weights, wiring
make kairic-up       # start
```

### General LLM contract — one port, models addressed by role

An older, broader serving contract for tools that are not opencode. Frontends
name a *role*; `config/llama-swap.yaml` decides what serves it, so swapping a
model never touches a client.

| role | model | size | prefill | decode |
| --- | --- | ---: | ---: | ---: |
| `fast` | Qwen3.6-35B-A3B Q4_K_M, vision | 20.74 GiB | 811 pp512 | 59.6 tg128 |
| `deep` | Qwen3.5-122B-A10B Q4_K_M, vision | 69.10 GiB | 215 pp512 | 26.4 tg128 |

Both at full 262144 native context, which is nearly free on these models
because most of their blocks are Gated DeltaNet with constant state rather than
a KV cache that grows with the window.

```
make llm-up
make chat Q="explain page faults" M=fast
```

### Media generation — image, 3D mesh, rigging, sprites

Text to a rigged GLB in one command, plus pixel-art sprites with real alpha.
Image generation lands within 3% of the published reference for this hardware,
and matches the Windows warm figure exactly.

```
make character SUBJ="an orc shaman"    # reference -> mesh -> rigged GLB
make asset PROMPT="a stone lantern"    # text -> textured GLB
make sprite SUBJ=orc                   # pixel-art sprite, alpha keyed
make viewer                            # browse what you made
```

`make help` lists every target with its arguments.

## Shared foundations

**One privileged step, once.** The amdgpu driver caps GTT at half of RAM, which
cannot hold a large model plus its context. Raising it is a kernel command line
change and needs a reboot. Full procedure, verification and rollback:
[docs/privileged-steps.md](docs/privileged-steps.md). Nothing in this repo can
escalate — `sudo -n` fails — so root commands are printed for you to run, never
attempted.

**Rootless podman throughout.** Containers are direct children of your user with
no privileged daemon. `--device=/dev/kfd --device=/dev/dri --group-add
keep-groups` is all the GPU access any of it needs.

**The Makefile is the interface.** Every service target traps its own shutdown,
so it cleans up on success, on failure and on Ctrl-C.

**Two commands that always work:**

```
make status      # what is running and what it is costing, including GPU memory
make stop-all    # stop everything this repo can start, then prove it
```

**Watch GTT, not RSS.** On a unified-memory APU the weights live in GTT. `ps`,
`top` and `podman stats` will report a few GB while 91 GiB is in use. Read
`/sys/class/drm/card*/device/mem_info_gtt_used`. This is the single most
misleading thing about the platform and it has caused real out-of-memory kills
here.

## Layout

```
config/          serving contracts and client wiring
harness/         container definitions for every engine
systemd/         user units; no system-level services
tools/           the small clients and probes the targets call
tests/           17 bats suites, run with `make test`
bench/           measurements, with method
docs/            setup, operations, privileged steps
.necklace/       the full development record, including what failed
```

`.necklace/` is worth reading before changing anything. Each cycle keeps a
ledger of what was measured, what was tried and abandoned, and why — including
the wrong turns, which are usually more useful than the conclusions.

## Testing

```
make setup    # bats, jq, podman check
make test     # 17 suites
```

Agents under evaluation run in containers with no host filesystem mounted, so a
test cannot reach into the working tree. `make test-isolation` checks that
boundary specifically.
