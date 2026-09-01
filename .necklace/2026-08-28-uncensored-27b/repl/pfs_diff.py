#!/usr/bin/env python3
"""Compare two .pfs sidecars entry by entry. Reports table agreement and per-entry byte match."""
import sys, struct, numpy as np
def load(p):
    f = np.memmap(p, dtype=np.uint8, mode='r'); h = struct.unpack('<8sIIIIQQQQQ', bytes(f[:64]))
    es = [struct.unpack('<HHBBHIIQQ', bytes(f[h[5] + 64 * i:h[5] + 64 * i + 32])) for i in range(h[4])]
    return f, h, es
fa, ha, ea = load(sys.argv[1]); fb, hb, eb = load(sys.argv[2])
print('header equal:', ha == hb, ha if ha != hb else '')
n = min(len(ea), len(eb)); print('entries', len(ea), len(eb))
for i in range(n):
    a, b = ea[i], eb[i]
    if a[:7] != b[:7] or a[8] != b[8]: print('TABLE MISMATCH', i, a, b); continue
    x = np.frombuffer(fa[a[7]:a[7] + a[8]], dtype=np.uint8); y = np.frombuffer(fb[b[7]:b[7] + b[8]], dtype=np.uint8)
    eq = (x == y).mean()
    if a[2] == 4:
        d = ((x & 15) == (y & 15)).mean() * 0.5 + ((x >> 4) == (y >> 4)).mean() * 0.5
        print(f'layer {a[0]:2d} kind {a[1]:2d} bytes {eq:.5f} nibbles {d:.5f}')
    else:
        print(f'layer {a[0]:2d} kind {a[1]:2d} exact {eq:.5f}')
