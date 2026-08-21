#!/usr/bin/env python3
"""Make a generated sprite's background transparent, deterministically.

Why not a colour match: the model paints "solid magenta" as whatever pink it
feels like -- #FF00FF was requested and something near #E8146E arrived -- so an
exact key matches nothing and a loose key eats the sprite.

Why flood fill from the edges rather than a global colour test: a sprite may
legitimately contain the background colour (a pink gem, a red cape). Filling
inward from the border stops at the sprite's outline and leaves interior pixels
alone. This is the "recover what the model composed" post-step, not a style
filter -- it adds no pixels and changes no colours.

Stdlib only. Reads and writes PNG directly.
"""
import sys, zlib, struct, argparse
from collections import deque

def read_png(path):
    d = open(path, "rb").read()
    i, idat, w, h, ct, bd = 8, b"", 0, 0, 0, 8
    while i < len(d):
        n = struct.unpack(">I", d[i:i+4])[0]; t = d[i+4:i+8]
        if t == b"IHDR": w, h, bd, ct = struct.unpack(">IIBB", d[i+8:i+18])
        elif t == b"IDAT": idat += d[i+8:i+8+n]
        i += 12 + n
    if bd != 8 or ct not in (2, 6):
        raise SystemExit(f"unsupported PNG: bitdepth={bd} colortype={ct}")
    bpp = 4 if ct == 6 else 3
    raw = zlib.decompress(idat); stride = w * bpp
    out = bytearray(); prev = bytearray(stride); pos = 0
    for _ in range(h):
        f = raw[pos]; pos += 1
        line = bytearray(raw[pos:pos+stride]); pos += stride
        for x in range(stride):
            a = line[x-bpp] if x >= bpp else 0
            b = prev[x]
            c = prev[x-bpp] if x >= bpp else 0
            if f == 1: line[x] = (line[x] + a) & 255
            elif f == 2: line[x] = (line[x] + b) & 255
            elif f == 3: line[x] = (line[x] + ((a + b) >> 1)) & 255
            elif f == 4:
                p = a + b - c; pa, pb, pc = abs(p-a), abs(p-b), abs(p-c)
                pr = a if (pa <= pb and pa <= pc) else (b if pb <= pc else c)
                line[x] = (line[x] + pr) & 255
        out += line; prev = line
    return w, h, bpp, bytearray(out)

def write_rgba(path, w, h, px):
    raw = bytearray()
    for y in range(h):
        raw.append(0)
        raw += px[y*w*4:(y+1)*w*4]
    def chunk(t, d):
        return struct.pack(">I", len(d)) + t + d + struct.pack(">I", zlib.crc32(t+d) & 0xffffffff)
    open(path, "wb").write(
        b"\x89PNG\r\n\x1a\n"
        + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 6, 0, 0, 0))
        + chunk(b"IDAT", zlib.compress(bytes(raw), 9))
        + chunk(b"IEND", b""))

def key(src, dst, tol=40):
    w, h, bpp, px = read_png(src)
    rgba = bytearray(w*h*4)
    for i in range(w*h):
        rgba[i*4:i*4+3] = px[i*bpp:i*bpp+3]
        rgba[i*4+3] = 255
    # Background colour is whatever sits in the corners, by majority.
    corners = [(0,0), (w-1,0), (0,h-1), (w-1,h-1)]
    ref = [sum(px[(y*w+x)*bpp+c] for x, y in corners)//4 for c in range(3)]
    seen = bytearray(w*h)
    q = deque()
    for x in range(w):
        for y in (0, h-1): q.append((x, y))
    for y in range(h):
        for x in (0, w-1): q.append((x, y))
    cleared = 0
    while q:
        x, y = q.popleft()
        if x < 0 or y < 0 or x >= w or y >= h: continue
        i = y*w + x
        if seen[i]: continue
        seen[i] = 1
        o = i*bpp
        if abs(px[o]-ref[0]) + abs(px[o+1]-ref[1]) + abs(px[o+2]-ref[2]) > tol*3:
            continue
        rgba[i*4+3] = 0; cleared += 1
        q.extend(((x+1,y), (x-1,y), (x,y+1), (x,y-1)))
    write_rgba(dst, w, h, rgba)
    return w, h, cleared, w*h

if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("src"); ap.add_argument("dst")
    ap.add_argument("--tolerance", type=int, default=40)
    a = ap.parse_args()
    w, h, cleared, total = key(a.src, a.dst, a.tolerance)
    print(f"{w}x{h}  transparent {cleared}/{total} = {100*cleared/total:.1f}%")
