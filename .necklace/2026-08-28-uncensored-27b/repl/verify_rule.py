import numpy as np, struct, sys, gguf
sys.path.insert(0,'/s'); from pfs import *
sys.argv=['x']; exec(open('/s/pack_pfs.py').read().split("# --- scale rule")[0])
r=gguf.GGUFReader('/work/stock-bf16.gguf'); T={t.name:t for t in r.tensors}
get=lambda l,n: bf16_to_f32(T[f'blk.{l}.{n}.weight'])
def load(p):
    f=np.memmap(p,dtype=np.uint8,mode='r'); h=struct.unpack('<8sIIIIQQQQQ',bytes(f[:64]))
    return f,[struct.unpack('<HHBBHIIQQ',bytes(f[h[5]+64*i:h[5]+64*i+32])) for i in range(h[4])]
def ls2(w, dtype, iters=2):
    w=w.astype(dtype); s=(np.abs(w).max(1)/dtype(7)).astype(dtype)
    for _ in range(iters):
        q=np.clip(np.rint(w/s[:,None]),-7,7).astype(dtype)
        s=((q*w).sum(1,dtype=dtype)/(q*q).sum(1,dtype=dtype)).astype(dtype)
    return np.clip(np.rint(w/s[:,None]),-7,7).astype(np.int8), s.astype(np.float32)
def check(tag, w, f, e):
    N,K=w.shape; codes=unpack_s4(np.frombuffer(f[e[0][7]:e[0][7]+N*K//2],dtype=np.uint8).reshape(N,K//2),K)
    sc=np.frombuffer(f[e[1][7]:e[1][7]+N*4],dtype=np.float32)
    for dt in (np.float32,np.float64):
        q,s=ls2(w,dt); ulp=np.abs(s.view(np.int32).astype(np.int64)-sc.view(np.int32).astype(np.int64))
        print(f'{tag} {dt.__name__}: rows codes-exact {(q==codes).all(1).sum()}/{N}  scale bit-exact {(s==sc).sum()}  ulp max {ulp.max()} ulp>1 {(ulp>1).sum()}')
f,e=load('/oracle/Qwen3.8-27B-Kairic-IU4-FFN.pfs')
check('ffn gate/up L0', rotate(np.concatenate([get(0,'ffn_gate'),get(0,'ffn_up')]),GATE_SEED), f, e[0:3])
check('ffn down L0', rotate(get(0,'ffn_down'),DOWN_SEED), f, e[3:6])
check('ffn gate/up L63', rotate(np.concatenate([get(63,'ffn_gate'),get(63,'ffn_up')]),GATE_SEED), f, e[63*6:63*6+3])
f,e=load('/oracle/Qwen3.8-27B-Kairic-IU4-GDN.pfs')
check('gdn qkvz L0', rotate(np.concatenate([get(0,'attn_qkv'),get(0,'attn_gate')]),GATE_SEED), f, e[0:3])
f,e=load('/oracle/Qwen3.8-27B-Kairic-IU4-GDN-Output.pfs')
check('gdn out L0', get(0,'ssm_out'), f, e[0:3])
