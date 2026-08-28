# Ledger — an uncensored Qwen3.8-27B at a speed worth using

Started 2026-08-28. No ticket.

## The problem as Nathan framed it

He wants an uncensored Qwen3.8-27B running on this machine at a speed he would
actually tolerate. The censored one already runs at 41.89 tok/s through Kairic
Edge, and that figure is the bar.

**Hard constraint, stated by Nathan before any work began:** the existing
kairic-edge setup is not to be modified and must keep working if this effort is
paused. That rules out editing `config/llama-swap-kairic.yaml`,
`config/run-kairic-serve.sh`, the installed unit, or the `localhost/kairic:v1.1`
image in place. Anything this cycle builds stands beside them.

## What was already established before the cycle opened

Not repeated here in full; the short version, because the spec rests on it:

- Kairic Edge is **not a fine-tune**. It is stock Qwen3.8-27B in GGUF plus three
  prepacked IU4 "compute views" (`.pfs` sidecars). Its own docs: "The GGUF
  remains the source of model behavior."
- **No published packer exists** for those sidecars. Established properly on the
  third attempt: all 44 branches and 13 tags of `ciru-ai/ROCmFPX` fetched and
  grepped, and the `PFSIU4`/`PFSIDE1` magic appears in exactly one file on every
  ref — `promptforge.cu`, the reader. No path on any ref suggests a packer.
- The **format is nonetheless fully specified** by that reader: container
  layout, 384 entries over 64 layers, the
  `[segment][N/64][K/segments/8][64]` packing, and both Hadamard seeds
  (`0xA511E9B3`, `0x63D83595`) as compile-time constants.
- **Abliterated Qwen3.8-27B exists in safetensors** — `huihui-ai`,
  `OBLITERATUS`, `AEON-7`, `orcarouter` — so no weight editing is needed here
  and every quantisation path is open.

## Two corrections that shaped the scope

Both were mine, both were caught by Nathan.

I claimed no packer existed twice before actually searching, once from a grep
that excluded `.cu` and `.cuh` files and once from a GitHub code search that
returns zero for `PF_IU4_FILE_BYTES` — because code search only indexes default
branches, and this code is on none of them. Absence of evidence from a blind
tool is not evidence.

And I offered `CHADROCK3.6-35B-UNCENSORED` and a 40B as options. Both are
Qwen**3.6**. The project is Qwen**3.8**-27B, and the architecture is the entire
reason the IU4 constants and sidecars are shaped as they are. That was
pattern-matching on the word "uncensored" while ignoring the only constraint
that mattered.

## The ROCmI4 lead collapses most of the problem

Nathan asked to chase `cafonez/Qwen3.8-27B-ROCmI4-MTP-GGUF` first, on the
grounds it might make the rest moot. It does.

**ROCmI4 is W4A4 IU4 delivered as an ordinary GGUF quantisation type. No
sidecars.** From the model card: "signed four-bit weight codes packed two per
byte with block scales", one 14.5 GB file plus an optional mmproj, MTP embedded.
Reported on a Ryzen AI MAX+ 395 with Radeon 8060S — Nathan's exact part:

    W4A4 IU4, MTP-16        49.40 tok/s mean
    full HumanEval, W4A4    44.39 tok/s mean
    non-speculative         ~13.8 tok/s

Against Kairic Edge's published 41.89 and the 46.64 aggregate this machine
measured last cycle. So the fast tier is not exclusive to the sidecar path.

**And the quantiser is public.** `charlie12345/ROCmFPX`, whose default-branch
head is `c49ebdbd` — the exact commit the card names as the minimum:

    tools/quantize/quantize.cpp:50
      { "Q4_0_ROCMI4", LLAMA_FTYPE_MOSTLY_Q4_0_ROCMI4,
        " 4.25 bpw native signed-nibble 4-bit (no codebook)" }
    include/llama.h:173
      LLAMA_FTYPE_MOSTLY_Q4_0_ROCMI4 = 118  // native signed-nibble 4-bit + UE4M3

It is also in `src/llama-quant.cpp` and `gguf-py/gguf/quants.py`, so both the C++
and Python sides carry it. Two branches, `experimental/rocmi4-iu4` and
`feat/rocmi4-exact`, show it is actively worked on rather than abandoned.

My first grep for it came back empty because I searched for `"ROCMI4"` and
`"IU4"` as standalone quoted tokens; the real name is `Q4_0_ROCMI4`. Third time
this project a too-narrow pattern produced a confident wrong answer.

**What this does to the plan.** The IU4 sidecar packer — the piece nobody
publishes and the thing the previous conversation was scoping — is no longer on
the critical path. The route becomes: abliterated safetensors, convert to GGUF,
quantise to `Q4_0_ROCMI4`, serve on `charlie12345/ROCmFPX`. Every step has a
public tool.

The packer stays interesting only if ROCmI4 measures materially slower than
Kairic here, and that is a measurement rather than an argument.

**Relevant to the hard constraint:** this repo already builds that fork, pinned
at `0fc9568` in `harness/Containerfile.rocmfpx-hip`, which predates ROCmI4. A
newer pin is needed, and it must go in a *new* image rather than moving that pin
or touching `Containerfile.kairic`, so the working setup is untouched.

## The rest of the chain is public too

`convert_hf_to_gguf.py` in `charlie12345/ROCmFPX` registers
`Qwen3_5ForConditionalGeneration` — the abliterated model's exact architecture —
and carries a dedicated `_Qwen35MtpMixin` plus `supports_mtp_export`,
`mtp_only` and `no_mtp` flags. MTP export is a first-class option, not an
accident.

`huihui-ai/Huihui-Qwen3.8-27B-abliterated` is bf16 safetensors, 27.78B
parameters, 73.8 GB, and its config reports:

    num_hidden_layers      64      matches PF_LAYERS
    hidden_size          5120      matches PF_H
    intermediate_size   17408      matches PF_I
    mtp_num_hidden_layers   1      the MTP head is declared

The dimensions matching matters beyond ROCmI4: it means the IU4 sidecar
constants would also fit this model unchanged, so the packer route stays open as
a fallback rather than being closed by architecture.

MTP is the difference between roughly 14 and roughly 44 tok/s on the card's own
figures, so whether it survives conversion is the single largest risk in the
chain. The config declaring it is necessary, not sufficient — abliteration edits
tensors rather than deleting them, so the weights should be intact, but that is
an inference and the conversion is where it would actually be lost.

## Costs, checked rather than assumed

    huihui-ai safetensors      73.8 GB   download
    GGUF bf16 intermediate    ~55.6 GB   convert
    Q4_0_ROCMI4               ~14.5 GB   quantise
    peak concurrent          ~129   GB

2.1 TB free, so disk is a non-issue. Worth noting the serving footprint goes the
right way: ROCmI4 is 14.5 GB against Kairic's 16.6 GB GGUF plus 11.4 GB of
sidecars, 28.0 GB total. Roughly half the resident memory for a model claiming
the same speed.
