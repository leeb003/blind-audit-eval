# Faithful replica of FisherYatesRejection.draw + ScaledEntropyProvider seed reuse.
import sys
from Crypto.Hash import keccak
MAX=2**256-1
def h(seed,nonce):
    k=keccak.new(digest_bits=256); k.update(seed.to_bytes(32,'big')+nonce.to_bytes(32,'big')); return int.from_bytes(k.digest(),'big')
def draw(lo,hi,count,seed):
    n=hi-lo+1; pool=list(range(lo,hi+1)); nonce=0
    for i in range(n-1,0,-1):
        while True:
            r=h(seed,nonce); lim=(MAX//(i+1))*(i+1)
            if r<lim: r%= (i+1); break
            nonce+=1
        pool[i],pool[r]=pool[r],pool[i]; nonce+=1
    return pool[:count]
N=int(sys.argv[1]); R=int(sys.argv[2]); B=int(sys.argv[3])
inN=0; eq0=0
from collections import Counter
joint=Counter()
for s in range(N):
    seed=h(0xC0FFEE,s)  # pseudo-random 256-bit seeds
    normals=draw(1,R,5,seed); bonus=draw(1,B,1,seed)[0]
    if bonus in normals: inN+=1
    if bonus==normals[0]: eq0+=1
    joint[(bonus, normals[0]%2)]+=1
print(f"R={R} B={B} N={N}: P(bonus in winning normals)={inN/N:.4f} (independent: {5/R:.4f}); P(bonus==normals[0])={eq0/N:.4f} (indep {1/R:.4f})")
