#!/usr/bin/env python3
"""Report PNG colour type and corner alpha, with no third-party dependencies.

Colour type 6 is RGBA. Corner alpha of 0 means the transparency is real rather
than merely representable -- a sprite on an opaque white field is also type 6
if it was saved that way.
"""
import sys, zlib, struct

def probe(path):
    d = open(path, "rb").read()
    i, idat, w, h, ctype, bitdepth = 8, b"", 0, 0, None, 8
    while i < len(d):
        n = struct.unpack(">I", d[i:i+4])[0]
        t = d[i+4:i+8]
        if t == b"IHDR":
            w, h, bitdepth, ctype = struct.unpack(">IIBB", d[i+8:i+18])
        elif t == b"IDAT":
            idat += d[i+8:i+8+n]
        i += 12 + n
    out = {"width": w, "height": h, "color_type": ctype, "corner_alpha": None}
    if ctype != 6 or bitdepth != 8:
        return out
    raw = zlib.decompress(idat)
    stride = w * 4 + 1
    # Row 0 filter byte is raw[0]; first pixel starts at raw[1]. Filter type 0
    # (None) is what these encoders emit for row 0 in practice; anything else
    # and we decline to guess rather than report a wrong number.
    if raw[0] != 0:
        return out
    out["corner_alpha"] = raw[4]
    return out

if __name__ == "__main__":
    r = probe(sys.argv[1])
    print(f"color_type={r['color_type']} corner_alpha={r['corner_alpha']} size={r['width']}x{r['height']}")
