# Replicating the uncensored Qwen3.8-27B at Kairic speed

Every step needed to go from public artifacts to an abliterated Qwen3.8-27B
that serves at ~48 tok/s on this machine's Kairic engine. Nothing here depends
on anything unpublished. Each step names the command, the input, the output,
and the check that proves it worked. The reasoning behind each choice is in
`.necklace/2026-08-28-uncensored-27b/ledger.md`; this file is the procedure.

Measured result on the machine in [README.md](../README.md):

    ablit + packed sidecars     48.44 tok/s +/-8.0%    HumanEval pass@1 92.7%
    Kairic Edge as shipped      48.75 tok/s +/-6.5%
    ablit ROCmI4 (no sidecars)  ~35 tok/s              91.5%

## What is being built

Kairic Edge is stock Qwen3.8-27B as a mixed-precision GGUF (ROCmFP4 with fifty
tensors promoted to Q6) plus three `.pfs` "sidecar" files holding W4 weights
in the layout its `promptforge` kernels consume directly. The GGUF recipe is
extractable and the fork's quantiser can apply it to any weights. The sidecar
packer was never published; `tools/pack_pfs.py` is a reimplementation
recovered from the engine's reader and validated byte-for-byte against the
published files (section 6).

So the pipeline is:

    abliterated safetensors
      -> bf16 GGUF                         (fork's converter)
      -> Kairic-recipe mixed-precision GGUF (fork's quantiser + extracted map)
      -> three .pfs sidecars                (tools/pack_pfs.py from the bf16 GGUF)
      -> served by Kairic's own engine and runner

## 0. Prerequisites

- The Kairic engine image `localhost/kairic:v1.1` (`make kairic-setup` builds it
  from `harness/Containerfile.kairic`). Used unmodified.
- Two images at ROCmFPX commit `c49ebdbd5c9f01ec242369f9e7f7967855f80cba`, built
  from the Containerfiles in `.necklace/2026-08-28-uncensored-27b/repl/`:

      podman build -t localhost/qwen-convert:c49ebdbd -f .necklace/2026-08-28-uncensored-27b/repl/Containerfile.convert .
      podman build -t localhost/rocmi4:c49ebdbd      -f .necklace/2026-08-28-uncensored-27b/repl/Containerfile.rocmi4 .

  `qwen-convert` is the fork's HF-to-GGUF converter with its pinned Python
  stack (also the numpy+gguf environment every Python tool below runs in).
  `rocmi4` carries `/engine/llama-quantize`.
- Kairic Edge's published GGUF and sidecars in `~/models/qwen3.8-kairic/`. Only
  needed for the validation step; the packer does not read them.
- ~200 GB free under `~/models`: 74 GB safetensors, 55 GB bf16 GGUF, 15 GB
  recipe GGUF, 11 GB sidecars, plus the same again for stock if validating.
- The HumanEval pool at `.necklace/2026-08-22-qwen38-27b/repl/humaneval.jsonl`.

## 1. Download the abliterated weights

    tools/hf-pardl.sh huihui-ai/Huihui-Qwen3.8-27B-abliterated ~/models/qwen3.8-ablit-src

Ranged parallel fetch, 32 parts per file, each file sha256-checked against
the LFS oid HuggingFace publishes. HuggingFace shapes throughput per
connection; a single stream gets ~1 MB/s, 32 saturate this box's link. The
script prints `ALL_DONE`; a hash mismatch exits 1 and deletes the file.

Check: `ls ~/models/qwen3.8-ablit-src/*.safetensors | wc -l` is 18.

## 2. Convert and quantise to Kairic's recipe

    .necklace/2026-08-28-uncensored-27b/repl/convert-and-quantise.sh

With `SRC` and `WORK` defaulting to `~/models/qwen3.8-ablit-src` and
`~/models/qwen3.8-ablit-work`. It does three things and stops at the first
failure:

1. `qwen-convert` writes `ablit-bf16.gguf` (54.7 GB, `--outtype bf16`, MTP
   layers retained). **This bf16 GGUF is also the packer's input.**
2. `check-map-names.py` confirms every tensor named in
   `kairic-precision-map.json` exists in the converted file and writes
   `tensor-types.txt`. The map was extracted from Kairic's GGUF by
   `extract-precision-map.py`; a name mismatch would leave tensors at the
   default type silently, which is why the check is a hard stop.
3. `llama-quantize --tensor-type-file tensor-types.txt --output-tensor-type
   q8_0 --token-embedding-type q6_k ... Q4_0_ROCMFP4` writes
   `Qwen3.8-27B-ablit-KairicRecipe.gguf`, and `extract-precision-map.py` on the
   output proves the mix landed.

Check: the last line is `CONVERT_QUANTISE_DONE` and the printed type counts
match Kairic's (fifty Q6_0_ROCMFPX tensors).

## 3. Pack the sidecars

    S=/home/nathan/code-stuff/ubuntu-strix-ai-setup/tools
    mkdir -p ~/models/qwen3.8-ablit-work/pfs
    podman run --rm -v ~/models/qwen3.8-ablit-work:/work:z -v "$S":/tools:ro,z \
      --entrypoint python3 localhost/qwen-convert:c49ebdbd \
      /tools/pack_pfs.py /work/ablit-bf16.gguf /work/pfs --prefix Qwen3.8-27B-ablit

Reads the bf16 GGUF, writes

    Qwen3.8-27B-ablit-Kairic-IU4-FFN.pfs          8,576,856,064 bytes
    Qwen3.8-27B-ablit-Kairic-IU4-GDN.pfs          2,019,569,664
    Qwen3.8-27B-ablit-Kairic-IU4-GDN-Output.pfs     756,953,088

About 15 minutes alone, an hour if another pack shares the disk. The byte
sizes are asserted by the engine's loader; anything else is rejected at
startup with `promptforge: wrong ... sidecar size`.

What the packer does, per layer (all of this was fitted against the published
files; see section 6 and the ledger for how):

- **FFN** (`PFSIU4F`, 64 layers): rebalance the intermediate dimension,
  `s_j = sqrt(max|down[:,j]| / max|up[j,:]|)` in f32, `up[j,:] *= s_j`,
  `down[:,j] /= s_j`, both rounded to bf16. Concatenate `[gate; up]`
  (34816 x 5120) and apply the block-1024 Hadamard with seed `0xA511E9B3`;
  `down` (5120 x 17408) gets seed `0x63D83595`. Quantise each row with the
  two-refit rule below.
- **GDN** (`PFSIU4G`, the 48 layers with `layer % 4 != 3`): `[attn_qkv;
  attn_gate]` (16384 x 5120), gate-seed Hadamard, two-refit rule.
- **GDN output** (`PFSIU4O`, same 48 layers): `ssm_out` (5120 x 6144), no
  Hadamard, `scale = max|w|/7` computed in f32, `code = rint(w / scale)` in f32.
- **Two-refit rule:** `s = max|w|/7`; twice: `q = clip(rint(w/s), -7, 7)`,
  `s = <q,w>/<q,q>`; final `q` from the last `s`. Done in f64.
- **Hadamard:** multiply column `k` by `hadamard_sign(k, seed)` (the hash in
  `promptforge_iu4.cuh`), in-place natural-order butterfly over each 1024
  block, multiply by 1/32. The engine applies the same transform to
  activations at runtime, so pre-rotated weights cancel it.
- **Layout:** signed 4-bit codes in [-7, 7], two per byte, low nibble first,
  row-major `[N][K/2]`; f32 scale per row; i32 sum of the row's codes. Entries
  in a 64-byte table after a 64-byte header, data at the table end rounded up
  to 4096.

## 4. Serve

    .necklace/2026-08-28-uncensored-27b/repl/sidecar-bench.sh

with `ARMS=ablit` serves and measures; `QUALITY=1` also scores HumanEval. It
runs `localhost/kairic:v1.1` with `config/run-kairic-serve.sh` mounted
read-only and these environment variables, which are the whole difference
from the daily-driver Kairic launch:

    MODEL_PATH=/models/qwen3.8-ablit-work/Qwen3.8-27B-ablit-KairicRecipe.gguf
    KAIRIC_FFN_SIDECAR=/models/qwen3.8-ablit-work/pfs/Qwen3.8-27B-ablit-Kairic-IU4-FFN.pfs
    KAIRIC_GDN_SIDECAR=/models/qwen3.8-ablit-work/pfs/Qwen3.8-27B-ablit-Kairic-IU4-GDN.pfs
    KAIRIC_GDN_OUTPUT_SIDECAR=/models/qwen3.8-ablit-work/pfs/Qwen3.8-27B-ablit-Kairic-IU4-GDN-Output.pfs

To make it the served model rather than a probe, point those four variables
at the ablit files in `config/llama-swap-kairic.yaml`'s `code` entry. Nothing
else in the runner changes.

Check: the container log contains
`"record":"promptforge_init","mode":"iu4_ffn"` with
`"wmma":"v_wmma_i32_16x16x16_iu4"` and `"transform":"block_hadamard_1024"`,
and no line matching `promptforge:.*(invalid|wrong|cannot|failed)`. If the
sidecars are rejected the server still starts, on the slow GGUF path, at
~28 tok/s; the init record is the only proof the fast path is live.

## 5. Measure

Throughput: `tools/concbench.py --streams 1 --reps 5 --maxtok 512 --workload
humaneval`, one stream, five repeats, spread reported. Quality:
`tools/humaneval_score.py --limit 164`. `sidecar-bench.sh` runs both and
appends to `repl/sidecar-bench.tsv` and `repl/sidecar-quality.tsv`. Expected:
per-stream within the reference's +/-6.5% of 48.75, pass@1 92.7%, and after
the script's exit trap `podman ps` empty and GTT back to ~4 GiB
(`/sys/class/drm/card1/device/mem_info_gtt_used`).

## 6. Validating the packer itself

This is the step that stops the packer becoming the next unknown. It packs
stock Qwen3.8-27B and diffs against Kairic's published sidecars, which were
built from stock bf16 (not from Kairic's FP4 GGUF; that gives only 86% code
agreement, and the ledger records the elimination).

    tools/hf-pardl.sh Qwen/Qwen3.8-27B ~/models/qwen3.8-stock-src
    mkdir -p ~/models/qwen3.8-stock-work/pfs
    podman run --rm -v ~/models/qwen3.8-stock-src:/src-model:ro,z -v ~/models/qwen3.8-stock-work:/work:z \
      localhost/qwen-convert:c49ebdbd /src-model --outfile /work/stock-bf16.gguf --outtype bf16
    podman run --rm -v ~/models/qwen3.8-stock-work:/work:z -v "$S":/tools:ro,z \
      --entrypoint python3 localhost/qwen-convert:c49ebdbd /tools/pack_pfs.py /work/stock-bf16.gguf /work/pfs
    for k in FFN GDN GDN-Output; do
      podman run --rm -v ~/models/qwen3.8-kairic:/oracle:ro,z -v ~/models/qwen3.8-stock-work/pfs:/p:ro,z -v "$S":/tools:ro,z \
        --entrypoint python3 localhost/qwen-convert:c49ebdbd \
        /tools/pfs_diff.py /p/Qwen3.8-27B-Kairic-IU4-$k.pfs /oracle/Qwen3.8-27B-Kairic-IU4-$k.pfs
    done

Expected, and what was measured (`repl/diff-*.txt`):

    FFN         header and table identical; codes 100.000% of nibbles on all
                64 layers; sums 99.98% bit-exact; scales ~90% bit-exact, the
                rest within 2 ulp (accumulation order)
    GDN-Output  100% bit-exact on every entry
    GDN qkvz    98.5% of nibbles; the residual is +/-1 at rounding ties from a
                sub-percent perturbation of the source not identified

Then `ARMS=stock sidecar-bench.sh` serves Kairic's GGUF with the repacked
sidecars: 47.56 tok/s +/-5.4% against the published 48.75 +/-6.5%. A packer
that produced the byte match but a slow serve would mean the engine is not
reading what the diff compared.

Anything that moves those numbers after a change to `pack_pfs.py` is a
regression in the packer, whatever the served model looks like.

## Where the format came from

`promptforge.cu` and `promptforge_iu4.cuh` in the ROCmFPX fork at
`c49ebdbd`, plus the patched composable_kernel `wmma_gemm.hpp` the engine
image carries. The container, entry kinds, dimensions and per-entry sizes are
in the loaders (`load_iu4_sidecar`, `load_gdn_iu4_sidecar`,
`load_gdn_output_iu4_sidecar`). The layout is plain row-major because the
unsegmented path hands the file to CK's `DeviceGemmMultipleD_Wmma_CShuffleV3`
with `K = PF_H/2` bytes; the segmented `[segment][N/64][K/8][64]` layout in
`gemm_u4s4` is only used with `PROMPTFORGE_IU4_SEGMENTED=1`, which Kairic does
not set. The quantisation rule and the FFN rebalancing are not in the engine
at all; they were fitted on exact rows against the published files, which is
why section 6 exists.
