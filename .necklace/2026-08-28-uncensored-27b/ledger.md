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

## Generation length was the last hypothesis, and it is not it

                    maxtok 512       maxtok 1024
    rocmi4          34.95 ±0.6%      34.59 ±1.9%
    kairic          48.75 ±6.5%      48.12 ±5.7%

Both flat. Doubling completion length moved neither engine outside its own
spread, so the short-completion theory for why cafonez's 44.39 does not
reproduce is dead alongside the other three.

## Conclusion on ROCmI4

**It caps near 35 tok/s here.** Five configurations, each attributed rather than
bundled:

    published flags          34.95    baseline
    + prompt cache           34.70    no effect
    + cache + big batch      35.11    no effect
    + cache + kairic spec    30.73    worse, despite 96.1% acceptance
    + generation length x2   34.59    no effect
    kairic reference         48.75

The W4A4 fast path was verified enabled by the server's own banner in every arm,
and draft acceptance ran 74.6% — better than Kairic's 72.8% — so neither a
silently-off build nor failed speculation explains it.

Against Kairic's 48.12-48.75, ROCmI4 costs **28%**. Against stock llama.cpp's
12.23 it still wins by 2.8x, so it is a real option rather than a dead end. It
is simply not the free lunch the card implied on this particular part.

**What this does to the plan.** The uncensored route through ROCmI4 is open,
cheap and entirely public — abliterated safetensors, the fork's own converter,
`Q4_0_ROCMI4`, done. It lands at ~35 tok/s, not the ~44 the card advertises and
not the ~48 Nathan runs today. So the choice is no longer "uncensored or fast"
but "uncensored at 72% of current speed, or build the packer".

The IU4 sidecar packer is better motivated now than when it was scoped. It is no
longer the only path to an uncensored model; it is the difference between 35 and
48, measured, on a route whose format is fully specified in `promptforge.cu` and
whose dimensions match the abliterated weights exactly.

## Two process failures worth keeping

**A five-hour idle gap.** `tune.log` last wrote at 02:58, `tune2.log` was created
at 07:41, and the only thing between them was Nathan pinging manually. The
`/loop` cron job was registered — `CronList` confirmed it — and fired zero times.
Asked why, I answered "the REPL was never idle" without checking, and the
timestamps say it was idle for essentially all of it. A confident causal story
offered in place of a two-second `stat`.

**An 80-minute job announced as 25.** The 2048-token sweep was launched with a
time estimate never computed. Eight tasks, six passes, 2048 tokens, at measured
rates, is 47 minutes for one arm. The arithmetic fits on one line and was worth
doing before starting, not after being asked.

## What Kairic Edge actually is — the earlier characterisation was wrong

Nathan pushed back on the claim that ROCmI4 is "the same W4A4 IU4 arithmetic" as
Kairic, delivered differently. Reading the two GGUFs settles it, and the claim
was wrong in both directions.

    Kairic  type 100 x454   type 102 x50   Q8_0 x1   Q6_K x1   F32 x360
    ROCmI4  type 108 x506                                       F32 x360

    GGML_TYPE_Q4_0_ROCMFP4 = 100
    GGML_TYPE_Q6_0_ROCMFPX = 102
    GGML_TYPE_Q4_0_ROCMI4  = 108

**Kairic's GGUF contains no IU4 at all.** It is ROCmFP4 with fifty tensors
promoted to a 6-bit type. The IU4 lives only in the sidecars, as a compute lane
for qualified shapes — which is exactly what the engine's own doc said
("the GGUF remains the source of model behavior") and which I read past.

The fifty are not arbitrary:

    ssm_alpha x12   ssm_beta x12   ssm_out x12     recurrent state paths
    ffn_down   x6   attn_output x4  attn_v   x4    residual-stream writers

Six-bit precisely where quantisation error accumulates across timesteps or
propagates into the residual stream, four-bit everywhere else. That is a
calibrated recipe, not a default.

ROCmI4 by contrast is uniform four-bit weights *and* four-bit activations, which
its own banner calls a "lossy prompt-processing path". The two designs share the
hardware instruction family and nothing else.

**This inverts what looked replicable.** The assumption had been: base is
commodity, sidecars are the secret. In fact the base is a tuned mixed-precision
assignment and both of its types are public quantise targets — and the
assignment itself is readable tensor-by-tensor out of the GGUF already on this
disk. Only the sidecars are unpublished.

Three measured points now bracket the unknown:

    ROCmFP4 base alone            ~22   (previous cycle, matched settings)
    uniform ROCmI4                ~35   (this cycle, five configurations)
    ROCmFP4/Q6 base + sidecars     ~48   (Kairic as shipped)

Nobody has measured a mixed-precision base *without* sidecars. That single
number decides the whole plan: if it lands near 45, the sidecars are worth
little and an uncensored build is a weekend. If it lands near 25, the sidecars
carry the format and the packer is the only route to Kairic-class speed.

**The process failure.** The tensor types were readable in ninety seconds with a
struct-unpacking loop and no dependencies. Instead the two model cards were
compared, both say "IU4", and a conclusion was drawn from marketing copy about
files sitting locally. Every wrong turn this cycle has that shape.

## The plan that follows, written down so it survives this session

Three steps, cheapest first, each with a stated abort condition. Recorded
because until now it existed only in a chat message.

**1. Extract Kairic's precision map.** Parse the 866 tensor entries out of
`Qwen3.8-27B-IU4-Kairic-Edge.gguf` into a name-to-type table, and check those
names against the abliterated model's tensor names. Minutes, no download, no
GPU. *Abort if:* the names do not correspond — different tensor naming would
mean the map cannot be transferred and the whole approach needs rethinking
before anything is fetched.

**2. Build a mixed-precision abliterated GGUF.** Fetch
`huihui-ai/Huihui-Qwen3.8-27B-abliterated` (73.8 GB, ranged parallel or it takes
twenty hours), convert with the fork's own `convert_hf_to_gguf.py` keeping MTP,
then quantise per the extracted map — `Q4_0_ROCMFP4` for the base,
`Q6_0_ROCMFPX` for the fifty. *Abort if:* `llama-quantize` cannot accept a
per-tensor precision assignment. That is unverified; if it only takes a single
global type, this becomes a much larger job and the plan should stop and be
re-scoped rather than bodged.

**3. Measure it without sidecars.** Same harness, same conditions, against the
Kairic reference. Fills the one hole in the bracket.

    ROCmFP4 base alone            ~22   measured, previous cycle
    uniform ROCmI4                ~35   measured, this cycle
    mixed-precision base           ???  <- step 3
    ROCmFP4/Q6 base + sidecars     ~48   measured, Kairic as shipped

**What the number decides.** Near 45: the sidecars contribute little, an
uncensored model at near-current speed is reachable with public tooling only,
and the packer is not needed. Near 25: the sidecars carry the format, and
writing the packer is the only route to Kairic-class speed on uncensored
weights.

**Costs, computed:** 73.8 GB download, ~55 GB bf16 intermediate, ~15 GB output,
against 2.1 TB free. Roughly half a day of mostly-unattended machine time.
Chain it as background tasks — the session cron registered and fired zero times
across a five-hour idle window, and background-task notifications are the only
wake signal that has worked.

**Constraint unchanged:** nothing touches the Kairic setup. New model directory,
new engine image, `harness/Containerfile.rocmfpx-hip` keeps its 0fc9568 pin.

## Step 1 done: both abort conditions cleared

**Kairic's precision map, extracted** (`repl/extract-precision-map.py`,
`repl/kairic-precision-map.json`). 866 tensors: 454 ROCmFP4, 360 F32 norms and
biases, 50 promoted to Q6_0_ROCMFPX, plus an Q8_0 output head and a Q6_K
embedding table.

The fifty are placed by depth, not by kind:

    ssm_alpha / ssm_beta / ssm_out   layers 48-62   (12 each)
    attn_output / attn_v             layers 51-63   (4 each)
    ffn_down                         layers 58-63   (6)
    output.weight                    Q8_0
    token_embd.weight                Q6_K

Late-layer promotion, deepest for the recurrent-state paths. Error introduced
near the output has no remaining layers to absorb it, and in a recurrent path it
compounds across timesteps as well as depth. That is a considered recipe and it
was sitting in a local file the whole time.

**Gate 1 — the quantiser accepts per-tensor assignment.** Better than hoped:

    --tensor-type tensor_name=ggml_type
    --tensor-type-file tensor_types.txt
    --output-tensor-type / --token-embedding-type

The file form exists precisely for a map this size, so the 506 quantised entries
can be handed over wholesale rather than as 506 flags.

**Gate 2 — the abliterated weights correspond.** 1199 safetensors tensors,
layers 0-63, 48 `linear_attn` blocks matching the 48 Gated DeltaNet layers
Kairic promotes, and MTP tensors present.

One thing step 2 must still verify rather than assume: the safetensors names are
`model.language_model.layers.N.linear_attn.*` while the map is keyed on GGUF
names like `blk.N.ssm_alpha.weight`. The converter performs that mapping, so the
map applies to the *converted* GGUF, not to the source. If the converter names
anything differently than Kairic's build did, the map will not line up and the
mismatch has to be caught by comparing name sets before quantising, not by
noticing bad output afterwards.

## Two self-inflicted process errors in one session

**Appending to a running script.** Step 3 was appended to `chain.sh` while that
script was executing. Bash reads a script by file offset, so editing one under a
live shell is undefined — it may run the addition, skip it, or garble the
parse. Nothing was lost because the chain was idle in a wait loop, but the fix
was to rewrite the file and relaunch, not to hope. Write the whole chain before
starting it.

**`pkill -f` matching its own command line, again.** `pkill -f 'chain.sh'` was
issued from a shell whose command line contained `chain.sh`, so it killed
itself along with both chains — exit 144, second time this session after the
identical mistake with the model filename. The fetch survived only because its
pattern differed.

Kill by pid. `chain.realpid` now holds it.
