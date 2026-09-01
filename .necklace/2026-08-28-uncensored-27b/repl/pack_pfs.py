#!/usr/bin/env python3
"""Pack Kairic-format IU4 sidecars (.pfs) from a bf16 GGUF of Qwen3.8-27B.

Format recovered from promptforge.cu / promptforge_iu4.cuh at ROCmFPX c49ebdbd and
verified byte-for-byte against Kairic Edge's published sidecars (see ledger).
  container : 64-byte header <8sIIIIQQQQQ, 64-byte entries <HHBBHIIQQ + 32 reserved
  weights   : row-major [N][K/2] bytes, signed 4-bit in [-7,7], low nibble = even k
  FFN up/down are rebalanced per intermediate channel and bf16-rounded before packing (rebalance_ffn)
  scale     : f32 per row      sum : i32 per row = sum of the row's signed codes
  FFN gate  : [ffn_gate; ffn_up] rows, K=5120, Hadamard(seed GATE)   FFN down: K=17408, Hadamard(seed DOWN)
  GDN qkvz  : [attn_qkv; attn_gate] rows, K=5120, Hadamard(seed GATE), layers l%4!=3
  GDN out   : ssm_out, K=6144, no Hadamard, layers l%4!=3
"""
import argparse, struct, sys, os
import numpy as np, gguf

GATE_SEED = 0xA511E9B3
DOWN_SEED = 0x63D83595
LAYERS = 64
H, I, GDN_N, VALUE_N = 5120, 17408, 16384, 6144

def hadamard_sign(n, seed):
    v = (np.arange(n, dtype=np.uint64) + np.uint64(seed)) & np.uint64(0xffffffff)
    v ^= v >> np.uint64(16); v = (v * np.uint64(0x7feb352d)) & np.uint64(0xffffffff)
    v ^= v >> np.uint64(15); v = (v * np.uint64(0x846ca68b)) & np.uint64(0xffffffff)
    v ^= v >> np.uint64(16)
    return np.where(v & np.uint64(1), -1.0, 1.0).astype(np.float32)

def fwht(x):
    n = x.shape[-1]; h = 1
    while h < n:
        x = x.reshape(*x.shape[:-1], n // (2 * h), 2, h)
        a = x[..., 0, :].copy(); b = x[..., 1, :].copy()
        x[..., 0, :] = a + b; x[..., 1, :] = a - b
        x = x.reshape(*x.shape[:-3], n); h *= 2
    return x

def rotate(w, seed):
    rows, K = w.shape
    x = (w * hadamard_sign(K, seed)[None, :]).reshape(rows, K // 1024, 1024)
    return (fwht(x) * np.float32(1 / 32)).reshape(rows, K)

def bf16_to_f32(t):
    raw = np.asarray(t.data)
    if t.tensor_type == gguf.GGMLQuantizationType.BF16:
        u = raw.view(np.uint16).astype(np.uint32) << 16
        return u.view(np.float32).reshape(t.shape[1], t.shape[0]) if len(t.shape) > 1 else u.view(np.float32)
    if t.tensor_type == gguf.GGMLQuantizationType.F32:
        return raw.view(np.float32).reshape(t.shape[1], t.shape[0])
    return gguf.quants.dequantize(raw, t.tensor_type).reshape(t.shape[1], t.shape[0]).astype(np.float32)

# --- quantisation rules, each fitted against the published sidecars --------------
def to_bf16(x):
    """Round f32 to bf16 (nearest-even) and back; Kairic stored the rebalanced FFN tensors in bf16."""
    u = x.astype(np.float32).view(np.uint32).astype(np.uint64); r = ((u >> 16) & 1) + 0x7fff
    return (((u + r) >> 16) << 16).astype(np.uint32).view(np.float32)

def quantise_refit2(w):
    """scale = max|w|/7, then twice: q = rint(w/scale) clipped to +-7, scale = <q,w>/<q,q>.
    FFN gate/up/down and GDN qkvz. Reproduces the published codes exactly (f64), scales within 2 ulp."""
    w = w.astype(np.float64); s = np.abs(w).max(1) / 7; s = np.where(s > 0, s, 1.0)
    for _ in range(2):
        q = np.clip(np.rint(w / s[:, None]), -7, 7)
        s = np.where((q * q).sum(1) > 0, (q * w).sum(1) / np.maximum((q * q).sum(1), 1e-30), s)
    return np.clip(np.rint(w / s[:, None]), -7, 7).astype(np.int8), s.astype(np.float32)

def quantise_maxabs_f32(w):
    """scale = max|w|/7 in f32, q = rint(w/scale) in f32. GDN output. Bit-exact against the published file."""
    w = w.astype(np.float32); s = (np.abs(w).max(1) / np.float32(7)).astype(np.float32); s = np.where(s > 0, s, np.float32(1))
    return np.clip(np.rint(w / s[:, None]), -7, 7).astype(np.int8), s

def rebalance_ffn(up, down):
    """Kairic scales intermediate channel j so up row j and down column j share a max: s_j = sqrt(max|down[:,j]|/max|up[j,:]|)."""
    mu = np.abs(up).max(1); md = np.abs(down).max(0)
    s = np.sqrt(md / mu).astype(np.float32)
    return to_bf16(up * s[:, None]), to_bf16(down / s[None, :])

RULES = {'refit2': quantise_refit2, 'maxabs_f32': quantise_maxabs_f32}

def pack_rows(codes):
    c = codes.astype(np.int8).astype(np.uint8) & 15
    return (c[:, 0::2] | (c[:, 1::2] << 4)).astype(np.uint8)

# --- container --------------------------------------------------------------
S4, F32, I32 = 4, 2, 3
def write_pfs(path, magic, layer_specs, build, T):
    """layer_specs: list of (layer, [(kind_w, kind_s, kind_sum, rows, K, name, rule)]); build(layer) -> {name: f32 matrix}."""
    entries = []; data_chunks = []
    n_entries = sum(len(specs) for _, specs in layer_specs) * 3
    data_offset = 64 + n_entries * 64
    data_offset = (data_offset + 4095) // 4096 * 4096
    off = data_offset
    with open(path, 'wb') as f:
        f.seek(data_offset)
        for layer, specs in layer_specs:
            mats = build(layer)
            for kw, ks, ksum, rows, K, name, rule in specs:
                w = mats[name]
                assert w.shape == (rows, K), (name, w.shape, rows, K)
                codes, scale = rule(w)
                sums = codes.sum(1, dtype=np.int64).astype(np.int32)
                packed = pack_rows(codes)
                for kind, dtype, rank, r, c, blob in [(kw, S4, 2, rows, K, packed.tobytes()),
                                                      (ks, F32, 1, rows, 1, scale.astype(np.float32).tobytes()),
                                                      (ksum, I32, 1, rows, 1, sums.tobytes())]:
                    entries.append(struct.pack('<HHBBHIIQQ', layer, kind, dtype, rank, 0, r, c, off, len(blob)) + b'\0' * 32)
                    f.write(blob); off += len(blob)
            print(f'  {magic.decode().strip(chr(0))} layer {layer} done', file=sys.stderr, flush=True)
        f.seek(0)
        f.write(struct.pack('<8sIIIIQQQQQ', magic, 1, 64, 64, n_entries, 64, n_entries * 64, data_offset, off, 0))
        f.write(b''.join(entries))
    return off

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('gguf'); ap.add_argument('outdir'); ap.add_argument('--prefix', default='Qwen3.8-27B')
    ap.add_argument('--layers', type=int, default=LAYERS); ap.add_argument('--which', default='ffn,gdn,out')
    a = ap.parse_args()
    r = gguf.GGUFReader(a.gguf); T = {t.name: t for t in r.tensors}
    get = lambda l, n: bf16_to_f32(T[f'blk.{l}.{n}.weight'])
    os.makedirs(a.outdir, exist_ok=True)
    gdn_layers = [l for l in range(a.layers) if l % 4 != 3]
    if 'ffn' in a.which:
        def build(l):
            up, down = rebalance_ffn(get(l, 'ffn_up'), get(l, 'ffn_down'))
            return {'gateup': rotate(np.concatenate([get(l, 'ffn_gate'), up]), GATE_SEED), 'down': rotate(down, DOWN_SEED)}
        specs = [(10, 11, 12, 2 * I, H, 'gateup', quantise_refit2), (13, 14, 15, H, I, 'down', quantise_refit2)]
        n = write_pfs(f'{a.outdir}/{a.prefix}-Kairic-IU4-FFN.pfs', b'PFSIU4F\0', [(l, specs) for l in range(a.layers)], build, T)
        print('FFN bytes', n)
    if 'gdn' in a.which:
        build = lambda l: {'qkvz': rotate(np.concatenate([get(l, 'attn_qkv'), get(l, 'attn_gate')]), GATE_SEED)}
        specs = [(20, 21, 22, GDN_N, H, 'qkvz', quantise_refit2)]
        n = write_pfs(f'{a.outdir}/{a.prefix}-Kairic-IU4-GDN.pfs', b'PFSIU4G\0', [(l, specs) for l in gdn_layers], build, T)
        print('GDN bytes', n)
    if 'out' in a.which:
        build = lambda l: {'out': get(l, 'ssm_out')}
        specs = [(40, 41, 42, H, VALUE_N, 'out', quantise_maxabs_f32)]
        n = write_pfs(f'{a.outdir}/{a.prefix}-Kairic-IU4-GDN-Output.pfs', b'PFSIU4O\0', [(l, specs) for l in gdn_layers], build, T)
        print('GDN-Output bytes', n)

if __name__ == '__main__':
    main()
