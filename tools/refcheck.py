#!/usr/bin/env python3
"""Check a character reference is one connected subject before meshing it.

TRELLIS reconstructs a single volume from a single image. An image containing
several disconnected subjects -- a figure plus a held staff that leaves the
silhouette, plus the inset bust a "reference sheet" prompt invites -- produces
a mesh that is not a standing figure, and the rig then rejects it with
NOT_A_CHARACTER.

That rejection currently arrives AFTER four minutes of meshing. This is the
same information for about a second, from the reference alone.

Stdlib only. Reuses the flood-fill idea from key_bg.py: everything reachable
from the border at the background colour is background; what remains is the
subject, and it should be one blob, not several.
"""
import sys, zlib, struct, argparse
from collections import deque

def load(path):
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
            b = prev[x]; c = prev[x-bpp] if x >= bpp else 0
            if f == 1: line[x] = (line[x]+a) & 255
            elif f == 2: line[x] = (line[x]+b) & 255
            elif f == 3: line[x] = (line[x]+((a+b)>>1)) & 255
            elif f == 4:
                pp = a+b-c; pa, pb, pc = abs(pp-a), abs(pp-b), abs(pp-c)
                pr = a if (pa <= pb and pa <= pc) else (b if pb <= pc else c)
                line[x] = (line[x]+pr) & 255
        out += line; prev = line
    return w, h, bpp, bytes(out)

def analyse(path, tol=40, step=2, min_frac=0.002):
    w, h, bpp, px = load(path)
    W, H = w // step, h // step
    def at(x, y):
        o = ((y*step)*w + x*step) * bpp
        return px[o], px[o+1], px[o+2]
    corners = [(0,0),(W-1,0),(0,H-1),(W-1,H-1)]
    ref = [sum(at(x,y)[c] for x,y in corners)//4 for c in range(3)]
    def is_bg(x, y):
        r,g,b = at(x,y)
        return abs(r-ref[0])+abs(g-ref[1])+abs(b-ref[2]) <= tol*3
    lab = bytearray(W*H)               # 0 unvisited, 1 background, 2+ subject blobs
    q = deque((x,y) for x in range(W) for y in (0,H-1))
    q.extend((x,y) for y in range(H) for x in (0,W-1))
    while q:                            # background = reachable from the border
        x,y = q.popleft()
        if not (0<=x<W and 0<=y<H) or lab[y*W+x]: continue
        if not is_bg(x,y): continue
        lab[y*W+x] = 1
        q.extend(((x+1,y),(x-1,y),(x,y+1),(x,y-1)))
    blobs = []
    nxt = 2
    for sy in range(H):
        for sx in range(W):
            if lab[sy*W+sx]: continue
            size = 0; qq = deque([(sx,sy)]); minx=maxx=sx; miny=maxy=sy
            while qq:
                x,y = qq.popleft()
                if not (0<=x<W and 0<=y<H) or lab[y*W+x]: continue
                lab[y*W+x] = nxt; size += 1
                minx,maxx = min(minx,x),max(maxx,x); miny,maxy = min(miny,y),max(maxy,y)
                qq.extend(((x+1,y),(x-1,y),(x,y+1),(x,y-1)))
            if size >= min_frac*W*H:
                blobs.append({"pixels": size,
                              "frac": round(size/(W*H), 4),
                              "bbox": [minx*step, miny*step, maxx*step, maxy*step]})
            nxt += 1
    blobs.sort(key=lambda b: -b["pixels"])
    return w, h, blobs

if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("image")
    ap.add_argument("--max-subjects", type=int, default=1)
    # A clean single-subject reference can still be too small to reconstruct.
    # Confirmed by a controlled test -- same subject, same seed, only IMGSIZE:
    #   orc      512   278x472 = 131k px  -> garbled mesh, NOT_A_CHARACTER
    #   orc     1024   526x964 = 507k px  -> rigged clean, 44 joints
    #   warrior 1024   442x948 = 419k px  -> rigged clean, 46 joints
    # 250k sits between the failure and the successes. Still an interpolation
    # from three points rather than a measured boundary, so it warns rather
    # than rejects.
    ap.add_argument("--min-subject-px", type=int, default=250_000)
    ap.add_argument("--quiet", action="store_true")
    a = ap.parse_args()
    w, h, blobs = analyse(a.image)
    if not a.quiet:
        print(f"{w}x{h}  significant subjects: {len(blobs)}")
        for i, b in enumerate(blobs):
            print(f"  [{i}] {b['frac']*100:5.1f}% of frame  bbox={b['bbox']}")
    if blobs:
        x0, y0, x1, y1 = blobs[0]["bbox"]
        area = (x1-x0) * (y1-y0)
        if area < a.min_subject_px:
            print(f"WARNING: the subject is {x1-x0}x{y1-y0} = {area//1000}k pixels. "
                  f"A reference this small reconstructs poorly -- a 131k-pixel orc "
                  f"produced a garbled mesh where a 419k-pixel warrior did not. "
                  f"Regenerate with IMGSIZE=1024, or crop tighter.", file=sys.stderr)

    if len(blobs) > a.max_subjects:
        print(f"REJECT: {len(blobs)} disconnected subjects. TRELLIS reconstructs one "
              f"volume per image, so the extras corrupt the mesh and the rig will "
              f"report NOT_A_CHARACTER. Re-roll the seed, or drop held props and "
              f"anything the prompt might render as an inset view.", file=sys.stderr)
        raise SystemExit(3)
