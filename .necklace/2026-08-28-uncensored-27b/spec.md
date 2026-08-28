# An uncensored Qwen3.8-27B at a speed worth using

No ticket.

## The problem

The daily driver is a censored model. Kairic Edge serves stock Qwen3.8-27B at a
published 41.89 tok/s, and this machine measured 46.64 aggregate on that
configuration last cycle. Every uncensored Qwen3.8-27B that exists ready to run
is published in a format that would cost most of that: stock llama.cpp GGUF
measures 12.23 tok/s here, roughly a quarter.

So the choice today is uncensored *or* fast, and the gap is large enough that
one of them does not get used.

**The obstacle was believed to be worse than it is.** Kairic's speed comes from
prepacked IU4 `.pfs` sidecars, and no tool to build those is published — checked
across all 44 branches and 13 tags of the engine's repository, where the format
magic appears only in the reader. That framing made the fast tier look
unreachable without reverse-engineering a packer.

Chasing `cafonez/Qwen3.8-27B-ROCmI4-MTP-GGUF` at Nathan's suggestion dissolved
that. **ROCmI4 is the same W4A4 IU4 arithmetic delivered as an ordinary GGUF
quantisation type with no sidecars at all**, and its quantiser is public:
`Q4_0_ROCMI4` is a first-class target in `charlie12345/ROCmFPX`, the fork this
repository already builds. Its card reports 44.39 tok/s on full HumanEval and
49.40 with MTP-16, measured on a Ryzen AI MAX+ 395 with a Radeon 8060S — this
exact part.

Every step from abliterated weights to a fast served model therefore has a
public tool. What is missing is evidence that any of it reproduces here.

## Actors

- Nathan, who wants an uncensored model he will actually use
- Nathan again, as the owner of a working setup he has asked not to disturb
- A reader of this repository's published numbers, who has to be able to tell
  which model produced which figure

## Actor-outcome pairs

| Actor | Must be able to observe |
| --- | --- |
| Nathan choosing what to run | ROCmI4 and Kairic Edge measured against each other on this machine, same harness and same conditions as the existing sweep, so the comparison is to the repository's own numbers rather than to a claim on a model card |
| Nathan choosing what to run | Whether the uncensored build keeps the speculative tier, stated as a measured draft-acceptance rate, because MTP is the difference between roughly 14 and roughly 44 tok/s |
| Nathan choosing what to run | An uncensored Qwen3.8-27B answering on this machine at a stated tok/s, with the conditions it was measured under |
| Nathan protecting his setup | That the existing Kairic contract still starts and answers after this work, and that nothing it depends on was edited |
| Nathan protecting his setup | One command that switches between the two, and one that shows which is running |
| A reader of the numbers | Which model, which format, which engine commit produced every figure, and enough method to repeat it |
| A reader of the numbers | Whether the uncensored model was checked for capability loss, or only for speed |

## Constraints

- **The existing Kairic setup is not to be modified.** Nathan's words, stated
  before work began. `config/llama-swap-kairic.yaml`,
  `config/run-kairic-serve.sh`, the installed unit and the
  `localhost/kairic:v1.1` image are all read-only for this cycle. Whatever is
  built stands beside them.
- `Q4_0_ROCMI4` requires `charlie12345/ROCmFPX` at `c49ebdbd` or later. This
  repository pins that same fork at `0fc9568` in `harness/Containerfile.rocmfpx-hip`,
  which predates the format. That pin cannot move without changing what the
  published ROCmFP4 comparison arm measured.
- MTP is worth roughly 3x on the card's own figures. Whether it survives
  conversion is the largest risk in the chain and is not settled by the config
  declaring `mtp_num_hidden_layers: 1`.
- The measured noise floor on this machine is about 13% peak-to-peak, so five
  repeats per arm is the floor and every figure carries its spread. Established
  last cycle, not re-derivable cheaply.
- The abliterated weights match the architecture exactly — 64 layers, hidden
  5120, intermediate 17408 — which is what makes both the ROCmI4 route and the
  sidecar fallback dimensionally possible.
- Disk is not a constraint: 2.1 TB free against a ~129 GB peak.

## Approach

**Superseded in part — see the ledger.** The measurements below replaced the
premise this section was written on, and the approach now reads as follows.

**The fast tier is not a single format, and ROCmI4 is not it.** Measured here at
five configurations, uniform ROCmI4 caps near 35 tok/s against Kairic's 48. The
gap is not cache, batching, speculation settings or generation length; all four
were isolated and none of them accounts for it.

**Kairic is a selective mixed-precision base plus a compute lane.** Its GGUF is
ROCmFP4 with fifty tensors promoted to 6-bit, placed on recurrent-state and
residual-writer paths, with IU4 living only in the sidecars. Both base types are
public quantisation targets, and the per-tensor assignment is readable out of
the GGUF already on this machine. Only the sidecar packer is unpublished.

**So the next measurement is a mixed-precision base without sidecars**, which
nobody has taken and which sits in the one gap between the three figures already
measured. It decides whether the unpublished packer matters at all or whether
most of Kairic's advantage lives in a recipe that can simply be read and reused.

**Everything stays additive.** A new engine image, a new model directory, a new
serving config. Nothing existing is edited, and the existing contract still
starting and answering is part of the deliverable.

**Speed is still not the only axis.** ROCmI4 announces itself as a lossy
prompt-processing path — four-bit activations, not just weights — and Kairic's
6-bit placement is evidently a quality decision. A capability measurement would
say what the precision choices actually buy, and no throughput table can.

## Open questions

| Question | Why it cannot be settled by reading or running |
| --- | --- |
| Is capability measurement in scope, or only speed and refusal behaviour? | HumanEval on the existing harness would give a comparable pass rate for perhaps an extra hour per arm, and the repository already has the tasks and the driver. Whether that is worth the time is a judgment about what Nathan wants to know, and running it does not answer whether he wanted it. |
| If ROCmI4 measures materially slower than Kairic here, does the IU4 sidecar packer come back onto the table, or is the slower uncensored model accepted? | Both are defensible and the data cannot choose. The packer is a real project with a validation path — pack stock weights, diff against the published sidecars — but it is weeks, not days, and only worth it if the gap it closes is large. |
