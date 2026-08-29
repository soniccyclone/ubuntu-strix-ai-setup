#!/usr/bin/env python3
"""Read Kairic Edge's per-tensor quantisation assignment out of its GGUF.

Kairic's base is ROCmFP4 with fifty tensors promoted to a 6-bit type, placed on
recurrent-state and residual-writer paths. That assignment is the tuned part of
the recipe and it is sitting in a local file; this pulls it out so it can be
applied to other weights.

No numpy, no gguf-py: a struct walk over the header is enough and has no deps.
"""
import collections
import json
import struct
import sys

GGML = {0: "F32", 1: "F16", 8: "Q8_0", 14: "Q6_K", 30: "BF16",
        100: "Q4_0_ROCMFP4", 101: "Q4_0_ROCMFP4_FAST", 102: "Q6_0_ROCMFPX",
        103: "Q8_0_ROCMFPX", 104: "Q3_0_ROCMFPX", 107: "Q2_0_ROCMFPX",
        108: "Q4_0_ROCMI4"}


def _rd(f, fmt):
    return struct.unpack(fmt, f.read(struct.calcsize(fmt)))


def _str(f):
    (n,) = _rd(f, "<Q")
    return f.read(n).decode("utf-8", "replace")


def _skip(f, t):
    if t in (0, 1, 7):   f.read(1)
    elif t in (2, 3):    f.read(2)
    elif t in (4, 5, 6): f.read(4)
    elif t in (10, 11, 12): f.read(8)
    elif t == 8:         _str(f)
    elif t == 9:
        (at,), (n,) = _rd(f, "<I"), _rd(f, "<Q")
        for _ in range(n):
            _skip(f, at)


def read_map(path):
    with open(path, "rb") as f:
        if f.read(4) != b"GGUF":
            sys.exit(f"{path}: not a GGUF")
        _rd(f, "<I")
        (ntensor,) = _rd(f, "<Q")
        (nkv,) = _rd(f, "<Q")
        for _ in range(nkv):
            _str(f)
            (t,) = _rd(f, "<I")
            _skip(f, t)
        out = {}
        for _ in range(ntensor):
            name = _str(f)
            (nd,) = _rd(f, "<I")
            dims = [_rd(f, "<Q")[0] for _ in range(nd)]
            (tt,) = _rd(f, "<I")
            _rd(f, "<Q")
            out[name] = {"type_id": tt, "type": GGML.get(tt, f"type_{tt}"),
                         "dims": dims}
    return out


def main():
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    m = read_map(sys.argv[1])
    counts = collections.Counter(v["type"] for v in m.values())
    print(f"  {len(m)} tensors")
    for k, v in counts.most_common():
        print(f"    {k:<20} {v:>5}")
    # The quantised tensors are the transferable part; F32 ones are norms and
    # biases that every quantiser leaves alone.
    quant = {k: v for k, v in m.items() if v["type"] not in ("F32", "F16", "BF16")}
    print(f"\n  quantised: {len(quant)}")
    hi = sorted(k for k, v in quant.items() if v["type"] == "Q6_0_ROCMFPX")
    print(f"  promoted to Q6_0_ROCMFPX: {len(hi)}")
    for n in hi[:6]:
        print(f"    {n}")
    if len(hi) > 6:
        print(f"    ... and {len(hi)-6} more")
    if len(sys.argv) > 2:
        with open(sys.argv[2], "w") as fh:
            json.dump({k: v["type"] for k, v in m.items()}, fh, indent=1, sort_keys=True)
        print(f"\n  wrote {sys.argv[2]}")


if __name__ == "__main__":
    main()
