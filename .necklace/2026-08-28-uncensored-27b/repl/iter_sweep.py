import numpy as np, struct, sys, gguf
sys.path.insert(0,'/s'); from pfs import *
sys.argv=['x']; exec(open('/s/pack_pfs.py').read().split("# --- scale rule")[0])
r=gguf.GGUFReader('/work/stock-bf16.gguf'); T={t.name:t for t in r.tensors}
get=lambda l,n: bf16_to_f32(T[f'blk.{l}.{n}.weight'])
def load(p):
    f=np.memmap(p,dtype=np.uint8,mode='r'); h=struct.unpack('<8sIIIIQQQQQ',bytes(f[:64]))
    return f,[struct.unpack('<HHBBHIIQQ',bytes(f[h[5]+64*i:h[5]+64*i+32])) for i in range(h[4])]
def sweep(tag, w, f, e, row0=0, R=256):
    N,K=w.shape; codes=unpack_s4(np.frombuffer(f[e[0][7]+row0*K//2:e[0][7]+(row0+R)*K//2],dtype=np.uint8).reshape(R,K//2),K)
    sc=np.frombuffer(f[e[1][7]+row0*4:e[1][7]+(row0+R)*4],dtype=np.float32); w=w[row0:row0+R].astype(np.float64)
    s=np.abs(w).max(1)/7; out=[]
    for it in range(12):
        q=np.clip(np.rint(w/s[:,None]),-7,7); out.append(f'{it}:{(q==codes).all(1).sum()}')
        s=(q*w).sum(1)/(q*q).sum(1)
    # convergence variant: iterate until codes stable
    s=np.abs(w).max(1)/7; qprev=None; conv=np.zeros(R,bool); sfin=s.copy(); qfin=None
    for it in range(50):
        q=np.clip(np.rint(w/s[:,None]),-7,7)
        if qprev is not None:
            newly=(q==qprev).all(1)&~conv; conv|=newly
        qfin=q if qfin is None else np.where(conv[:,None],qfin,q); qprev=q; s=(q*w).sum(1)/(q*q).sum(1)
    print(f'{tag}: exact rows per iter {" ".join(out)} | converge: {(qfin==codes).all(1).sum()} (converged {conv.sum()})  stored/(amax/7) med {np.median(sc/(np.abs(w).max(1)/7)):.4f}')
f,e=load('/oracle/Qwen3.8-27B-Kairic-IU4-FFN.pfs')
gu=rotate(np.concatenate([get(0,'ffn_gate'),get(0,'ffn_up')]),GATE_SEED)
sweep('gate L0', gu, f, e[0:3]); sweep('up L0', gu, f, e[0:3], row0=17408)
sweep('down L0', rotate(get(0,'ffn_down'),DOWN_SEED), f, e[3:6])
f,e=load('/oracle/Qwen3.8-27B-Kairic-IU4-GDN.pfs'); qz=rotate(np.concatenate([get(0,'attn_qkv'),get(0,'attn_gate')]),GATE_SEED)
sweep('qkv L0', qz, f, e[0:3]); sweep('z L0', qz, f, e[0:3], row0=10240)
f,e=load('/oracle/Qwen3.8-27B-Kairic-IU4-GDN-Output.pfs'); sweep('out L0', get(0,'ssm_out'), f, e[0:3])
