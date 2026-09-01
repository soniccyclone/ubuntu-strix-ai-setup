#!/usr/bin/env python3
"""Diff a converted GGUF's tensor names against Kairic's precision map.

The map is keyed on the names Kairic's own build produced. This converter is a
different build of a different fork, so the names are expected to match but not
guaranteed to. A silent mismatch is the dangerous case: unmatched tensors keep
the default type, the file quantises without error, and the result looks like a
disappointing measurement rather than a broken recipe.

Emits a --tensor-type-file for the tensors that DO match, and fails if the
promoted set is not fully covered -- those fifty are the entire point.
"""
import json
import sys

sys.path.insert(0, __file__.rsplit("/", 1)[0])
from importlib import import_module
read_map = import_module("extract-precision-map".replace("-", "_")) if False else None

# Reuse the struct walk rather than duplicating it.
import struct


def _rd(f, fmt): return struct.unpack(fmt, f.read(struct.calcsize(fmt)))
def _str(f):
    (n,) = _rd(f, "<Q"); return f.read(n).decode("utf-8", "replace")
def _skip(f, t):
    if t in (0, 1, 7): f.read(1)
    elif t in (2, 3): f.read(2)
    elif t in (4, 5, 6): f.read(4)
    elif t in (10, 11, 12): f.read(8)
    elif t == 8: _str(f)
    elif t == 9:
        (at,), (n,) = _rd(f, "<I"), _rd(f, "<Q")
        for _ in range(n): _skip(f, at)


def names(path):
    out = []
    with open(path, "rb") as f:
        f.read(4); _rd(f, "<I")
        (nt,) = _rd(f, "<Q"); (nkv,) = _rd(f, "<Q")
        for _ in range(nkv):
            _str(f); (t,) = _rd(f, "<I"); _skip(f, t)
        for _ in range(nt):
            out.append(_str(f))
            (nd,) = _rd(f, "<I")
            for _ in range(nd): _rd(f, "<Q")
            _rd(f, "<I"); _rd(f, "<Q")
    return out


def main():
    gguf, mapfile, ttfile = sys.argv[1], sys.argv[2], sys.argv[3]
    have = set(names(gguf))
    kmap = json.load(open(mapfile))
    quant = {k: v for k, v in kmap.items()
             if v not in ("F32", "F16", "BF16")}
    promoted = {k: v for k, v in quant.items() if v == "Q6_0_ROCMFPX"}

    missing_promoted = [k for k in promoted if k not in have]
    matched = {k: v for k, v in quant.items() if k in have}
    print(f"  converted GGUF tensors : {len(have)}")
    print(f"  map quantised entries  : {len(quant)}")
    print(f"  matched                : {len(matched)}")
    print(f"  promoted (Q6) in map   : {len(promoted)}")
    print(f"  promoted MISSING       : {len(missing_promoted)}")
    for n in missing_promoted[:8]:
        print(f"      {n}")

    if missing_promoted:
        print("  the promoted set is the whole point of the recipe; refusing to proceed")
        return 1

    # EVERY quantised tensor is pinned, not just the promoted fifty.
    #
    # Naming only the fifty and passing Q4_0_ROCMFP4 as the base ftype does NOT
    # give Kairic's recipe: llama-quantize applies its own per-tensor heuristics
    # on top of the base type, promoting attention-V and FFN-down tensors to
    # Q5_K/Q6_K on its own. A first run produced 287 ROCmFP4, 123 Q5_K and 44
    # Q6_K against the intended 454/0/0 -- an 18.55 GB file where Kairic's is
    # 16.6 GB, and a measurement of something other than the recipe.
    #
    # Pinning all 506 leaves the tool no discretion.
    with open(ttfile, "w") as fh:
        for k, v in sorted(matched.items()):
            fh.write(f"{k}={v.lower()}\n")
    import collections as _c
    dist = _c.Counter(v for v in matched.values())
    print(f"  wrote {ttfile} pinning all {len(matched)} quantised tensors")
    for k, v in dist.most_common():
        print(f"      {k:<20} {v:>5}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
