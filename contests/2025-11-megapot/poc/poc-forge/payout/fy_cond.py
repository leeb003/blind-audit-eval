import sys
sys.argv=[sys.argv[0]]+sys.argv[1:]
exec(open('fy_sim.py').read().split("N=int")[0])
from collections import defaultdict
N=int(sys.argv[1]); R=int(sys.argv[2]); B=int(sys.argv[3])
cnt=defaultdict(int); tot=defaultdict(int); eq0=0; inN=0
for s in range(N):
    seed=h(0xBEEF,s); normals=draw(1,R,5,seed); b=draw(1,B,1,seed)[0]
    tot[b]+=1; eq0+= b==normals[0]; inN+= b in normals
    for v in normals: cnt[(b,v)]+=1
dev=max(abs(cnt[(b,v)]/tot[b]-5/R) for b in tot for v in range(1,R+1))
print(f"R={R} B={B}: P(b==n0)={eq0/N:.4f} P(b in normals)={inN/N:.4f}  max|P(v in normals|b)-{5/R:.3f}|={dev:.4f}")
