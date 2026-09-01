import numpy as np, struct, sys, gguf
sys.path.insert(0,'/s'); from pfs import *
sys.argv=['x']; exec(open('/s/pack_pfs.py').read().split("# --- scale rule")[0])
rs=gguf.GGUFReader('/work/stock-bf16.gguf'); TS={t.name:t for t in rs.tensors}
rk=gguf.GGUFReader('/oracle/Qwen3.8-27B-IU4-Kairic-Edge.gguf'); TK={t.name:t for t in rk.tensors}
get=lambda l,n: bf16_to_f32(TS[f'blk.{l}.{n}.weight']).astype(np.float64)
kget=lambda l,n,K: deq_rocmfp4(np.array(TK[f'blk.{l}.{n}.weight'].data),K).astype(np.float64)
np.set_printoptions(precision=4,suppress=True,linewidth=180)
up_s,up_k=get(0,'ffn_up'),kget(0,'ffn_up',5120); dn_s,dn_k=get(0,'ffn_down'),kget(0,'ffn_down',17408); g_s,g_k=get(0,'ffn_gate'),kget(0,'ffn_gate',5120)
ls=lambda a,b: (a*b).sum(-1)/(a*a).sum(-1)   # b ~ f*a
su=ls(up_s,up_k); sd=ls(dn_s.T,dn_k.T); sg=ls(g_s,g_k)
rowcorr=lambda a,b: ((a*b).sum(-1)/np.sqrt((a*a).sum(-1)*(b*b).sum(-1)))
print('gate factor med',np.median(sg),'p1/p99',np.percentile(sg,[1,99]),' rowcorr med',np.median(rowcorr(g_s,g_k)))
print('up factor s_j: p1/med/p99',np.percentile(su,[1,50,99]),' rowcorr med',np.median(rowcorr(up_s,up_k)))
print('down col factor: p1/med/p99',np.percentile(sd,[1,50,99]),' colcorr med',np.median(rowcorr(dn_s.T,dn_k.T)))
print('product su*sd: p1/med/p99',np.percentile(su*sd,[1,50,99]))
# candidate formulas for s_j from stock stats
mu=np.abs(up_s).max(1); md=np.abs(dn_s).max(0); nu=np.linalg.norm(up_s,axis=1); nd=np.linalg.norm(dn_s,axis=0); mg=np.abs(g_s).max(1)
for name,cand in [('sqrt(md/mu)',np.sqrt(md/mu)),('sqrt(nd/nu)',np.sqrt(nd/nu)),('md/mu',md/mu),('nd/nu',nd/nu),('sqrt(md*mg)/mu',np.sqrt(md*mg)/mu)]:
    r=su/cand; print(f'  {name:16s}: su/cand med {np.median(r):.4f} spread p5-p95 {np.percentile(r,[5,95])} corr(log) {np.corrcoef(np.log(su),np.log(cand))[0,1]:.4f}')
# is the factor global-scalar-ish per layer? check layer 5 too
up_s5,up_k5=get(5,'ffn_up'),kget(5,'ffn_up',5120); su5=ls(up_s5,up_k5); print('layer5 up factor p1/med/p99',np.percentile(su5,[1,50,99]))
# rotated-domain test: does rebalanced stock (up*su) reproduce up codes with 2-refit rule?
f=np.memmap('/oracle/Qwen3.8-27B-Kairic-IU4-FFN.pfs',dtype=np.uint8,mode='r'); R=256; K=5120
codes=unpack_s4(np.frombuffer(f[28672+17408*K//2:28672+(17408+R)*K//2],dtype=np.uint8).reshape(R,K//2),K).astype(np.float64)
sc=np.frombuffer(f[89157632+17408*4:89157632+(17408+R)*4],dtype=np.float32).astype(np.float64)
w=rotate((up_s[:R]*su[:R,None]).astype(np.float32),GATE_SEED).astype(np.float64); s=np.abs(w).max(1)/7
for it in range(4):
    q=np.clip(np.rint(w/s[:,None]),-7,7); print(f' rebalanced-up iter{it}: codes match {(q==codes).mean():.4f} rows exact {(q==codes).all(1).sum()} scale ratio med {np.median(s/sc):.4f}'); s=(q*w).sum(1)/(q*q).sum(1)
print(' su[:8]',su[:8],' sc/(amax/7)[:8]',(sc/(np.abs(rotate(up_s[:R].astype(np.float32),GATE_SEED)).max(1)/7))[:8])
