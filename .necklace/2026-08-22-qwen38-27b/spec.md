# Qwen3.8-27B on Strix Halo

No ticket. Cycle 3. The machine, the measurement discipline and the existing roster come from
`.necklace/2026-08-19-local-claude-suite/`; this document does not re-derive them.

## The problem

Nathan asked for a dedicated cycle on this model. The model is not the interesting part — two
projects publish quantisations and engines built specifically for `gfx1151` and claim throughput
that would beat the roster he already runs. Whether those claims hold on his machine is the question.

**On arithmetic the model should lose badly.** A dense 27B streams all its weights per token. The
roster's daily driver is a MoE that streams roughly 3 B active and measures **59.6 tok/s** here. The
published stock baseline for Qwen3.8-27B is 12.27 tok/s, and it reproduces almost exactly on this
box: **12.23**, 0.3% apart, on the same binary behind every row in `bench/results.md`. So the model
is four to five times slower than what is already installed, and every claim to the contrary rests
on something other than the weights.

**That something is speculative decoding, and it is real.** Measured here, matched container, model,
flags, prompt and deterministic sampling, three runs each:

| | tokens | tok/s |
| --- | ---: | --- |
| speculation off | 365 | 12.7, 12.7, 12.7 |
| MTP, n_max 4, strict | 348 | 22.8, 22.5, 22.7 |

**+78%.** This also settles a question cycle 1 left open: the 122B HALO quant was judged with
`llama-bench`, which never speculates, so its MTP head was dead weight carrying bandwidth cost. Any
benchmark that cannot exercise MTP understates an MTP-carrying model.

**The backend question is answered too.** Cycle 1 deferred ROCm-vs-Vulkan on published figures
alone. Measured here on the same quantisation:

    ROCmFP4-FAST   Vulkan   202.1 pp512   11.91 tg128
    ROCmFP4-FAST   ROCm     242.7 pp512   12.80 tg128

HIP wins prefill by 20.1% and decode by 7.5%, close to the ~20% prefill figure cycle 1 cited.

**ROCm belongs in a container, not on the machine.** Ubuntu 26.04 has no AMD-published suite; its
own ROCm 7.1 packaging gives a working runtime but no working HIP compiler; and reconciling the two
needs an apt pin forcing downgrades across ~24 system packages plus hand-copied `.so` shims. On a
noble base image none of that exists. Rootless podman reaches `gfx1151` unprivileged, as cycle 2
established.

## Actors

- Nathan choosing what backs a role in the roster
- Nathan running a coding task against a local model
- Whoever administers this box six months from now
- The machine itself

## Actor-outcome pairs

| Actor | Must be able to observe |
| --- | --- |
| Nathan choosing a roster model | A throughput figure for this model measured in the configuration it would actually serve in, including speculation, not a benchmark that cannot exercise it |
| Nathan choosing a roster model | The same figure for each competing engine and quantisation, taken on identical prompts with deterministic sampling |
| Nathan running a coding task | The model answering through the same contract as every other role, with no separate client |
| Whoever administers this | Every engine build reproducible from a pinned commit and a pinned toolchain, without anything installed on the host |
| Whoever administers this | Which published claims reproduced, which did not, and by how much — with the harness that produced each |
| The machine | No ROCm, no HIP toolchain and no vendor apt repository left behind |

## Constraints

- **Nothing goes on the host.** ROCm, its compiler and its libraries live in container images.
  Verified: `ggml_rocm_init: found 1 ROCm devices` inside a rootless, unprivileged container.
- Every engine is pinned by commit and every toolchain by version, because these are third-party
  forks under active development and an unpinned build measures something different next week.
- Builds are tuned for this machine — `GGML_NATIVE=ON`, `AMDGPU_TARGETS=gfx1151`. The container
  makes the build reproducible, not the binary portable.
- Speculation must be measured through a server with real requests. `llama-bench` cannot do it, and
  the difference is 78%.
- Comparisons are deterministic: temperature 0, matched prompts, repeated runs. Sampling variance is
  larger than several of the differences being measured.
- 110 GiB GPU-addressable, from cycle 1. Not a limit for a 27B at any quantisation here.
- Kairic Edge additionally requires a second fork and a patched Composable Kernel, and ships
  10.57 GiB of accelerator sidecars beside a 15.48 GiB model.

## Approach

**Measure each engine against a baseline that reproduces a published number, then trust the rest.**
The stock arm reproducing 12.27 to within 0.3% is what makes every other measurement in this cycle
credible; without it, a slow result is indistinguishable from a broken setup. Two of today's
failures produced plausible tables from a container with no GPU driver and a benchmark that could
not speculate — in both cases the number looked like a measurement and was an artefact.

**One container per engine, pinned, built where the toolchain is supported.** Vendor toolchains
target the distributions vendors test. Reconciling that with the host's distribution costs system
packages and gains nothing, because the requirement was never "install ROCm" but "a process with
ROCm must reach the GPU".

**Separate the claims before testing them.** Quantisation, engine and speculation are three
different assertions and the projects publish them separately. Measuring only the end-to-end figure
cannot say which part earned the gain, and the parts do not move together — the quantisation was
worth little here, the backend a fifth, and speculation most of it.

**Adoption is decided by the roster, not by the headline.** A model earns a role by beating what
currently holds it, measured the same way. Publishing a number that beats a different model's
number on a different harness is not that.
