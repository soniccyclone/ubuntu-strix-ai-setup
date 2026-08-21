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
    # For the FIRST pixel of row 0 every PNG filter reduces to the raw bytes:
    # the left neighbour and the row above are both zero, so Sub, Up, Average
    # and Paeth all add nothing. So the corner alpha is readable regardless of
    # which filter the encoder chose. An earlier version bailed unless the
    # filter was None and reported "unknown" on perfectly readable files.
    out["corner_alpha"] = raw[4]
    return out

if __name__ == "__main__":
    r = probe(sys.argv[1])
    print(f"color_type={r['color_type']} corner_alpha={r['corner_alpha']} size={r['width']}x{r['height']}")
