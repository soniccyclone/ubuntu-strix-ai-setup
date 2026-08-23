# Benchmark matrix — llama.cpp b10502, Vulkan/RADV, gfx1151, ngl 999, fa on, r 3

> Rows below were measured at the original 61.41 GiB GTT ceiling. After raising it
> to 110 GiB (2026-08-20), the daily driver re-measured at **811.5 pp512 / 59.6
> tg128**, up 14.7% and 2.9%. Fresh boot and bigger ceiling are confounded; see
> ledger probe 9. Relative ordering between rows is unaffected.

`gpu_busy_percent` sat at 95-98% during the measured window of every run.
Harness: `bench.sh`. Machine idle, no downloads, verified before each run.

| Model | Attention | Packager | Quant | Size | pp512 | tg128 |
| --- | --- | --- | --- | ---: | ---: | ---: |
| Qwen3.6-35B-A3B | hybrid DeltaNet | bartowski | Q4_K_M (plain) | 20.74 GiB | 707.4 | **58.0** |
| Qwen3.6-35B-A3B | hybrid DeltaNet | unsloth | Q8_0 (plain) | 34.36 GiB | 705.1 | 46.3 |
| Qwen3.6-35B-A3B | hybrid DeltaNet | unsloth | UD-Q6_K_XL (dyn) | 29.65 GiB | 641.1 | 46.6 |
| Qwen3.6-35B-A3B | hybrid DeltaNet | unsloth | UD-Q4_K_XL (dyn) | 20.81 GiB | 321.8 | 25.9 |
| Qwen3-Coder-30B-A3B | conventional | unsloth | UD-Q4_K_XL (dyn) | 16.45 GiB | 773.8 | **78.6** |
| Qwen3-Coder-30B-A3B | conventional | lmstudio | Q4_K_M (plain) | 17.35 GiB | 769.7 | 70.5 |

## What varies with what

**Packaging is not a constant factor — it interacts with architecture.**

    Qwen3.6 (DeltaNet)   plain 58.0  vs dynamic 25.9   dynamic is 2.24x SLOWER
    Qwen3-Coder (conv.)  plain 70.5  vs dynamic 78.6   dynamic is 1.12x FASTER

Unsloth's Ultra Dynamic scheme substitutes IQ-family types on selected tensors.
On conventional attention that is a small win. On the DeltaNet path it lands on
RADV kernels that are catastrophically slow. Same packager, same quant level,
opposite sign.

Within the dynamic quants the penalty shrinks as bits go up — UD-Q4_K_XL 25.9,
UD-Q6_K_XL 46.6 — consistent with IQ substitution being most aggressive at low
bpw.

**Architecture, compared fairly (plain against plain, Q4_K_M against Q4_K_M):**

    conventional 70.5  vs  hybrid DeltaNet 58.0   -> 1.21x decode, 1.09x prefill

Not the 3.0x that probe 6 reported. That 3.0x was real as an arithmetic fact
about two dynamic quants, but it was measuring the packaging interaction, not
the architecture.

**Quant level, plain against plain, same model:**

    Q4_K_M 20.74 GiB 58.0   ->   Q8_0 34.36 GiB 46.3
    66% more bytes per token, 20% slower. Sub-linear: partly compute-bound.

## Roster consequence

Qwen3.6-35B-A3B at plain Q4_K_M does 58.0 t/s with vision, a 262k native
context, and 73.4% SWE-bench Verified. Qwen3-Coder-30B-A3B does 70.5 t/s with
none of those. A 1.21x throughput edge does not buy back the capability gap.

**Qwen3.6-35B-A3B, plain Q4_K_M, takes the daily-driver and vision roles.**
Nathan's recollection was correct; two intermediate conclusions of mine were not.

## Selection rule this establishes

Benchmark the exact file. Not the model, not the quant level, not the
architecture — the file, from that packager, on that backend. Every one of the
three interacts with the others, and the interaction reverses sign between
models. Nothing on a model card predicts any of it.

## 122B deep tier — 2026-08-20, at the 110 GiB GTT ceiling

| Quant | Packaging | Size | params | pp512 | tg128 |
| --- | --- | ---: | ---: | ---: | ---: |
| Q4_K_M | lmstudio, homogeneous plain | 69.10 GiB | 122.11 B | **215.0** | **26.36** |
| q80-q6k_ffn | Beinsezii, hand-mixed for Halo, F32 SSM, MTP head | 96.78 GiB | 124.64 B | 170.0 | 19.81 |

Homogeneous wins: 1.33x decode, 1.26x prefill. The prediction that hand-placed
tensor types would beat raw size was **wrong on Vulkan**.

### Why, and how it reconciles with the 35B results

    35B-A3B   3B active    20.74 -> 34.36 GiB   1.66x bytes   1.25x slower   sub-linear
    122B-A10B 10B active   69.10 -> 96.78 GiB   1.40x bytes   1.33x slower   ~proportional

The 35B is compute-bound and the 122B is bandwidth-bound. Active parameter count
is what moves a model across that line on this machine: 3 B active leaves the
shaders as the limit, 10 B active makes the memory controller the limit. Size is
nearly free in the first regime and costs proportionally in the second.

So the rule is not "prefer large quants" or "prefer small quants". It is:

    measure where the model sits. Below the crossover, buy quality with size.
    Above it, size is paid for in tokens per second at roughly one for one.

### Two reasons this is not the last word on the HALO quant

**llama-bench does not exercise MTP.** The HALO file carries an `nextn` MTP head
— that is its headline feature and the 2.5 B extra params llama-bench counts. A
plain `tg128` run never speculates, so those weights are dead weight in this
measurement while still costing bandwidth. Under `llama-server` with MTP
speculative decoding the ranking could invert, and published Strix Halo numbers
elsewhere cite ~36 t/s via MTP speculation on a comparable model. This benchmark
measures the quant with its main feature switched off.

**The author tuned on ROCm, not Vulkan.** His published figures are ROCm
(pp2048 275.0, tg256 16.62). The F32 SSM tensors and the Q8_0/Q6_K split were
chosen against ROCm kernels. Nothing here says that choice is wrong on the
backend it was made for.

Both are cheap to settle and neither is settled. The homogeneous quant takes the
deep role for now on the strength of the only comparison actually run.

## Qwen3.8-27B — Kairic Edge IU4 vs ROCmFP4, served, MTP on

HumanEval tasks 0-9, chat-adapted, greedy, 512-token cap. Kairic launched via
the vendor's `scripts/run-kairic-edge-gfx1151.sh` at release defaults (262144
context, 8 GiB prompt cache, `-ctxcp 32`, `--cache-idle-slots`); ROCmFP4 given
identical speculation and reasoning settings. Script:
`.necklace/2026-08-22-qwen38-27b/repl/kairic-humaneval.sh`.

| arm | cold tok/s | hot tok/s | draft accept | serves tool calls |
| --- | ---: | ---: | ---: | --- |
| Kairic Edge, greedy argmax fast path | 40.03 | **56.72** | 76.2% | no |
| Kairic Edge, compatibility mode | 28.41 | **41.89** | 76.2% | yes |
| ROCmFP4-FAST, matched settings | 24.35 | **22.21** | 95.7% | yes |

Kairic's published HumanEval 0-9 hot slice is 48.78 tok/s. This machine
measured 56.72 — the vendor claim reproduces and is exceeded.

    Kairic fast path vs ROCmFP4      2.55x  (+155%)
    Kairic compatibility vs ROCmFP4  1.89x  (+88.6%)
    fast path vs compatibility       1.35x  (+35.4%)

Compatibility mode is the configuration to run: it serves tool calls,
temperature, grammar and logprobs, and still nearly doubles ROCmFP4. The fast
path refuses all of those, so its extra 35% is not reachable from an agent.
`response_format: json_schema` fails in both Kairic modes with a sampler-init
fault specific to this branch; `json_object`, raw GBNF and the `tools:` path
all work, so agents are unaffected.

**The gain is verification speed, not acceptance.** ROCmFP4 accepts 95.7% of
drafts and is still 2.5x slower. Kairic accepts fewer and wins, because its
IU4 lane covers `decode_rows:[2,3,4,5]` — MTP verification batches. M1 decode
is not native IU4 and the vendor does not claim it is.

**Throughput on this model tracks MTP draft acceptance, which tracks how
predictable the output is.** Code accepts 76.2% and runs at 56.72; discursive
prose accepts 46-47% and runs at 16.8-21.0. Quote a figure with its workload
or the figure means nothing. An earlier revision of this file reported 19.62
for Kairic from prose prompts with unmatched ROCmFP4 settings; that number was
measuring prose and is superseded by the table above.

Both engines are containerized: `harness/Containerfile.kairic` (ciru-ai fork,
`release/kairic-edge-qwen38-27b-v1.1`, patched Composable Kernel) and
`harness/Containerfile.rocmfpx-hip`. Nothing is installed on the host.
