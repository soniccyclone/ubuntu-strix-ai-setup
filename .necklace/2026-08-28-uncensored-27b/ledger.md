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

## The build flag that would have wasted the whole probe

`GGML_HIP_ROCMI4_W4A4` **defaults to OFF**. From the fork's README, and the
reason it matters:

> The server prints `ROCmI4 W4A4: enabled` when the accelerated path is active.

Without the flag the engine still builds, still loads a `Q4_0_ROCMI4` model, and
still answers. It simply never takes the accelerated path. The result would have
been a working server measuring somewhere near the card's non-speculative 13.8
tok/s, and the obvious reading of that is "ROCmI4 is slow here" rather than "the
build was wrong". A whole probe answered backwards by a default.

So the startup banner is checked before any number is believed, rather than the
build flags being trusted.

## What the publisher's own launch script settles

`launch-rocmi4-mtp.sh` ships in the model repo, which removes a lot of guessing.
Its flags differ from this repository's Kairic runner in ways that matter:

    -np 1  -c 262144           same as Kairic now runs after the slot change
    -b 512 -ub 256             Kairic uses 2048 / 512
    --spec-draft-n-max 16      Kairic uses 4
    --spec-draft-p-min 0.60    Kairic uses 0.0
    --spec-mtp-strict-qwen     no Kairic equivalent
    (no --kairic-edge)         that switch is the other fork's

`ROCMFPX_COMMIT.txt` pins `c49ebdbd5c9f01ec242369f9e7f7967855f80cba`, matching
the README and the fork's current default-branch head.

**A comparison caveat to carry into the CUJ.** The draft window differs by 4x
between the two runners, and last cycle established that speculation settings
move throughput a long way. So an honest Kairic-versus-ROCmI4 number has to say
whether it is comparing *each engine at its publisher's recommended settings* or
*both at matched settings*. Those answer different questions and only the first
is what either publisher measured.

## Staying off the existing setup

The engine is a new image, `localhost/rocmi4:c49ebdbd`, built from a
Containerfile that lives in this cycle's `repl/` rather than in `harness/`.
`harness/Containerfile.rocmfpx-hip` keeps its `0fc9568` pin: it predates ROCmI4,
and it is what the published ROCmFP4 arm was measured on, so moving it would
quietly change a number already in `bench/`.

Weights go to `~/models/qwen3.8-rocmi4/`, beside `qwen3.8-kairic/` and not into
it. Nothing in `config/`, `systemd/` or the installed unit is touched.

## HuggingFace throttles one connection, not the link

The model download settled at ~1.05 MB/s with a 3h43m estimate, which read like
the concurrent image build saturating the network. It was not. A second
connection pulling a 64 MB range finished in 3.72 s — **17 MB/s** — while the
first was still crawling.

So it is per-connection shaping, and the fix is ranged parallel fetch.
`repl/`-adjacent `pardl.sh` splits into N parts, fetches them concurrently, and
verifies the result against the publisher's own `checksums.sha256` before
declaring success. A torn or short chunk has to fail loudly rather than produce
a GGUF that loads and misbehaves.

**This matters more later than now.** The abliterated safetensors are 73.8 GB.
At 1 MB/s that is 20 hours; at parallel rates it is under an hour. Whoever runs
the conversion stage should not discover that by starting a serial download and
going to bed.

**And a self-inflicted one worth writing down.** Killing the slow transfer with
`pkill -f 'Qwen3.8-27B-Q4_0_ROCMI4.gguf'` matched the pattern against *its own
shell's* command line, which contained that string, so the command killed
itself mid-write and left the replacement script truncated. Exit 144 with a
half-written file and a still-running orphan is a confusing state to debug at
one in the morning. Match on a pid, or on something the killing command does not
itself contain.

## ROCmI4 measured, and it does not reproduce its card

At cafonez's own published launch flags, on the harness the last cycle
validated, one stream, HumanEval pool of eight, five repeats:

    rocmi4-pub   per-stream 34.95 ±0.6%   aggregate 29.20 ±0.9%   accept 74.6%   36 GiB
    kairic-ref   per-stream 48.75 ±6.5%   aggregate 44.35 ±8.7%   accept 72.8%   47 GiB

ROCmI4 is 28% slower than Kairic here, and 21% below the 44.39 tok/s its own
card reports for full HumanEval on this same silicon. The ±0.6% spread means
that is not noise.

**The fast path was genuinely on**, so this is not the silently-OFF build the
default flag invites:

    ROCmI4 W4A4: enabled for device 0 (lossy prompt-processing path)
    Qwen strict MTP: boundary-safe multi-row verification ... for exact greedy output
    draft acceptance = 0.776, mean acceptance length 10.35 of a 16-token window

Acceptance is *better* than Kairic's, so speculation is not the deficiency.

**And the comparison was unfair, in a direction I set up without noticing.**
Kairic's runner passes `--cache-prompt --cache-idle-slots --cache-ram 16384`.
cafonez's launch script passes none of them, and I used his flags verbatim. The
harness runs a warming pass and then five repeats of the same eight tasks —
exactly the workload a prompt cache exists to exploit. Kairic reused its
prefill across every repeat; ROCmI4 recomputed it every time.

That single difference could account for the whole gap, and it sits alongside
three others introduced at once: batch 512/256 against 2048/512, draft window 16
against 4, and p-min 0.60 against 0.0. Four variables, one number.

`repl/tune-rocmi4.sh` isolates them — cache alone, cache plus batching, cache
plus Kairic's speculation settings, and everything matched. The interesting
answer is not which engine wins a bundled comparison; it is which of those four
differences the 14 tok/s actually lives in.

**Also worth carrying forward:** the W4A4 banner says *lossy prompt-processing
path*. That is 4-bit activations, not just 4-bit weights, and it is a quality
claim the speed table cannot see. It strengthens the spec's open question about
whether this cycle measures capability or only throughput.

## The cache hypothesis was wrong, and so was the whole framing

`repl/tune-rocmi4.sh`, four arms isolating the four differences:

    published flags        34.95 ±0.6%   accept 74.6
    + prompt cache         34.70 ±4.0%   accept 74.6
    + cache + big batch    35.11 ±0.2%   accept 74.6
    + cache + kairic spec  30.73 ±0.5%   accept 96.1
    + all matched          30.58 ±3.9%   accept 96.1
    kairic reference       48.75 ±6.5%   accept 72.8

The prompt cache explains none of it. Neither does batching. Both land inside
the noise of the unmodified arm.

Matching Kairic's speculation settings makes ROCmI4 **worse** — 30.73 against
34.95 — while raising acceptance from 74.6% to 96.1%. That inversion is the
useful part: a four-token draft accepted 96% of the time yields fewer tokens per
verification cycle than a sixteen-token draft accepted 75% of the time.
Acceptance rate on its own is not a proxy for throughput, and reading it as one
would have pointed at exactly the wrong setting.

**ROCmI4 caps near 35 tok/s here under every configuration tried**, against
Kairic's 48.75 and its own card's 44.39. That is a property of the format on
this machine, not of how it was invoked.

I had proposed the cache as the likely explanation with some confidence, on the
strength of noticing a real asymmetry in the harness. The asymmetry was real and
the inference from it was wrong; the measurement cost twenty minutes and settled
what argument could not.

## What remains untested about the card's claim

Ours is a pool of eight HumanEval tasks with roughly 162-token completions. The
card reports 44.39 for "full HumanEval". Speculation amortises its setup over
the length of a generation, so short completions are the regime where a
sixteen-token draft window pays worst. Longer generations are the one plausible
explanation left for the gap between 34.95 and 44.39 that is not simply "it does
not reproduce".

That is worth one arm before the format is written off, because the uncensored
plan rides on it.
