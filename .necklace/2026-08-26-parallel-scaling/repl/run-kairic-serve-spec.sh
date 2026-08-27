#!/usr/bin/env bash
set -euo pipefail

readonly server="${LLAMA_SERVER:-./build-kairic/bin/llama-server}"
readonly model="${MODEL_PATH:?set MODEL_PATH to Qwen3.8-27B-IU4-Kairic-Edge.gguf}"
readonly ffn="${KAIRIC_FFN_SIDECAR:?set KAIRIC_FFN_SIDECAR}"
readonly gdn="${KAIRIC_GDN_SIDECAR:?set KAIRIC_GDN_SIDECAR}"
readonly gdn_output="${KAIRIC_GDN_OUTPUT_SIDECAR:?set KAIRIC_GDN_OUTPUT_SIDECAR}"
readonly rocm="${ROCM_PATH:-/opt/rocm}"

readonly host="${HOST:-127.0.0.1}"
readonly port="${PORT:-8080}"
readonly context="${CONTEXT:-262144}"
readonly cache_ram="${CACHE_RAM:-8192}"
readonly alias_name="${MODEL_ALIAS:-main}"
readonly compatibility_mode="${KAIRIC_EDGE_COMPATIBILITY_MODE:-0}"

case "$compatibility_mode" in
  0) readonly target_argmax_fastpath=1 ;;
  1) readonly target_argmax_fastpath=0 ;;
  *)
    echo "KAIRIC_EDGE_COMPATIBILITY_MODE must be 0 or 1: $compatibility_mode" >&2
    exit 2
    ;;
esac

for required in "$server" "$model" "$ffn" "$gdn" "$gdn_output"; do
  [[ -r "$required" ]] || {
    echo "missing or unreadable required artifact: $required" >&2
    exit 1
  }
done

[[ "$port" =~ ^[0-9]+$ ]] || {
  echo "PORT must be numeric: $port" >&2
  exit 2
}

readonly server_dir="$(cd -- "$(dirname -- "$server")" && pwd)"
readonly library_path="$server_dir:$rocm/lib:$rocm/lib/rocm_sysdeps/lib:$rocm/lib/llvm/lib:$rocm/llvm/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

# Sampling below is Qwen's recommended LIVE set, per the card's
# compatibility-mode section, NOT the vendor runner's benchmark defaults.
# Those are --temp 0 --top-p 1 --top-k 0 with every penalty at zero: correct for
# reproducible measurement, wrong for agent work. Greedy decode with
# repeat_penalty 1.0 has nothing to break a repetition attractor, so a
# tool-calling loop re-emits the same command until something kills it --
# observed doing exactly that in opencode for the better part of an hour.
#
# SAMPLING: Qwen's THINKING-mode values, because reasoning is on below.
# Qwen publishes two sets and they are not interchangeable:
#   thinking      temp 1.0  top_p 0.95  top_k 20  min_p 0  presence 0.0
#   non-thinking  temp 0.7  top_p 0.80  top_k 20  min_p 0  presence 1.5
# An earlier revision here used the non-thinking pair WITH thinking enabled,
# including presence_penalty 1.5 -- the maximum Qwen suggests, which their docs
# warn "may occasionally result in language mixing and a slight decrease in
# model performance". A presence penalty also actively hurts code, where
# repeating identifiers and syntax is correct rather than degenerate.
# These same values are what the GGUF itself advertises in general.sampling.
#
# SLOTS: -np 2, not the vendor's 1. opencode's `general` subagent is documented
# to "execute multiple units of work in parallel", and agents inherit the main
# model, so with one slot every subagent call evicts the main session's KV and
# forces a full re-prefill -- minutes at 228 tok/s on a large context. Two slots
# keep the main session on 0 and subagents on 1. Context is TOTAL across slots,
# so this is 131072 per slot; opencode's limit.context must match that, not the
# 262144 the model supports.
#
# Reasoning is ON with format 'deepseek', not the vendor runner's
# '--reasoning off --reasoning-format none'. Two separate things were wrong for
# interactive use: 'off' means no thoughts are generated at all, and 'none'
# leaves whatever tags appear unparsed inside message.content -- which is how you
# get empty <think></think> rendered as literal text. 'deepseek' extracts them
# into message.reasoning_content, which is the field opencode renders as a
# thinking block.
#
# Do not put comments inside the continuation lines below. A backslash joins the
# next line, so a '#' there comments out the remainder of the command; doing that
# silently dropped every flag after --spec-draft-backend-sampling, including
# --reasoning off, and the failure only showed up in `podman top`.
exec /usr/bin/env \
  ROCM_PATH="$rocm" \
  HIP_VISIBLE_DEVICES=0 \
  HSA_OVERRIDE_GFX_VERSION=11.5.1 \
  LD_LIBRARY_PATH="$library_path" \
  GGML_CUDA_GRAPH_OPT=0 \
  LLAMA_TARGET_GREEDY_ARGMAX_FASTPATH="$target_argmax_fastpath" \
  LLAMA_MTP_CPU_ARGMAX_FASTPATH=1 \
  PROMPTFORGE_TARGET_ONLY=0 \
  PROMPTFORGE_MODE=iu4_ffn \
  PROMPTFORGE_IU4_SIDECAR="$ffn" \
  PROMPTFORGE_SIDECAR="$ffn" \
  PROMPTFORGE_IU4_HADAMARD=1 \
  PROMPTFORGE_IU4_SEGMENTED=0 \
  PROMPTFORGE_ENABLE_FFN_KEEPERS=0 \
  PROMPTFORGE_FFN_KEEPERS=late6 \
  PROMPTFORGE_ENABLE_GDN=1 \
  PROMPTFORGE_ENABLE_GDN_W8=0 \
  PROMPTFORGE_GDN_SIDECAR_OVERRIDE="$gdn" \
  PROMPTFORGE_GDN_SIDECAR="$gdn" \
  PROMPTFORGE_GDN_IU4_HADAMARD=1 \
  PROMPTFORGE_ENABLE_GDN_KEEPERS=0 \
  PROMPTFORGE_ENABLE_GDN_OUTPUT=1 \
  PROMPTFORGE_GDN_OUTPUT_SIDECAR="$gdn_output" \
  PROMPTFORGE_GDN_OUTPUT_KEEPERS=v3_lateq6 \
  PROMPTFORGE_ENABLE_SMALLM_IU4=1 \
  PROMPTFORGE_ENABLE_SMALLM_GDN_IU4=1 \
  PROMPTFORGE_ENABLE_SMALLM_GDN_OUTPUT_IU4=0 \
  PROMPTFORGE_ENABLE_IU4_DECODE_M2_M5=0 \
  PROMPTFORGE_OUTPUT_K8_STRICT_GREEDY=0 \
  "$server" -m "$model" --alias "$alias_name" \
    --host "$host" --port "$port" --jinja -dev ROCm0 -ngl 999 \
    -c "$context" -b 2048 -ub 512 -fa on -ctk f16 -ctv f16 \
    -t 16 -tb 32 -np ${KAIRIC_SLOTS:-2} -ctxcp 32 --cache-ram "$cache_ram" \
    --cache-prompt --cache-idle-slots --metrics \
    --kairic-edge \
    --spec-type ${KAIRIC_SPEC_TYPE:-draft-mtp} \
    --spec-draft-device ROCm0 --spec-draft-ngl 999 \
    --spec-draft-type-k f16 --spec-draft-type-v f16 \
    --spec-draft-n-max 4 --spec-draft-n-min 0 \
    --spec-draft-p-min 0.0 --spec-draft-p-split 0.10 \
    --spec-draft-backend-sampling \
    --temp ${KAIRIC_TEMP:-1.0} --top-p ${KAIRIC_TOP_P:-0.95} \
    --top-k ${KAIRIC_TOP_K:-20} --min-p ${KAIRIC_MIN_P:-0.0} \
    --presence-penalty ${KAIRIC_PRESENCE_PENALTY:-0.0} \
    --reasoning ${KAIRIC_REASONING:-on} \
    --reasoning-format ${KAIRIC_REASONING_FORMAT:-deepseek} \
    --reasoning-budget ${KAIRIC_REASONING_BUDGET:--1}
