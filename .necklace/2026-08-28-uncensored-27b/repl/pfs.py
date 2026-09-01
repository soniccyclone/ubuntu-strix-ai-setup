import numpy as np
CODEBOOK=np.array([0,1,2,3,4,6,8,10,0,-1,-2,-3,-4,-6,-8,-10],dtype=np.float32)
def ue4m3(e):
    e=e.astype(np.int32); ex=e>>3; m=e&7
    v=np.where(ex==0, m*2.0**-10, (8+m)*2.0**(ex-11.0))
    return np.where(e<=0x7e, v, 0.0).astype(np.float32)
def deq_rocmfp4(raw, ne0):
    # raw: (rows, nbytes) uint8 ; block = 16 qs + 2 scale bytes
    rows=raw.shape[0]; nb=ne0//32
    b=raw.reshape(rows,nb,18)
    qs=b[:,:,:16]; d0=ue4m3(b[:,:,16])[:,:,None]; d1=ue4m3(b[:,:,17])[:,:,None]
    lo=CODEBOOK[qs&15]*d0; hi=CODEBOOK[qs>>4]*d1
    return np.concatenate([lo,hi],axis=2).reshape(rows,ne0)
def hadamard_sign(n, seed):
    v=(np.arange(n,dtype=np.uint64)+np.uint64(seed))&np.uint64(0xffffffff)
    v^=v>>np.uint64(16); v=(v*np.uint64(0x7feb352d))&np.uint64(0xffffffff)
    v^=v>>np.uint64(15); v=(v*np.uint64(0x846ca68b))&np.uint64(0xffffffff)
    v^=v>>np.uint64(16)
    return np.where(v&np.uint64(1), -1.0, 1.0).astype(np.float32)
def fwht(x):  # in-place natural-order butterfly over last axis (block 1024), matches kernel
    x=x.copy(); n=x.shape[-1]; h=1
    while h<n:
        x=x.reshape(*x.shape[:-1], n//(2*h), 2, h)
        a=x[...,0,:].copy(); b=x[...,1,:].copy()
        x[...,0,:]=a+b; x[...,1,:]=a-b
        x=x.reshape(*x.shape[:-3], n); h*=2
    return x
def rotate(w, seed):
    rows,K=w.shape
    x=(w*hadamard_sign(K,seed)[None,:]).reshape(rows,K//1024,1024)
    return (fwht(x)*(1/32)).reshape(rows,K)
GATE_SEED=0xA511E9B3; DOWN_SEED=0x63D83595
def unpack_s4(bytes_, K):
    lo=(bytes_&15).astype(np.int8); hi=(bytes_>>4).astype(np.int8)
    lo=np.where(lo>7,lo-16,lo); hi=np.where(hi>7,hi-16,hi)
    return np.stack([lo,hi],-1).reshape(bytes_.shape[0],K)
