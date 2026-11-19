# Expected payout per $1 ticket, designed (independent bonusball) vs actual when bonusballMax == normalBallMax
# (bonusball == first winning normal). Uses test-suite params: n=30, weights below, minPayout $1 on weighted tiers.
from math import comb
n=30; B=30; C=comb(n,5); price=1.0; edge=0.3; reserve=0.2
w=[0,.17,0,.13,.12,.05,.05,.02,.02,.01,.04,.39]; minp=1.0
minTickets=4_200_000; pool=minTickets*(1-edge)*price   # pool size that yields bonusballMax == 30
N=[comb(5,t//2)*comb(n-5,5-t//2)*(1 if t%2 else B-1) for t in range(12)]
minAlloc=sum(N[t]*minp for t in range(12) if w[t]>0)
use_min = pool*0.2+minAlloc < pool
rem = pool-minAlloc if use_min else pool
pay=[(minp if (use_min and w[t]>0) else 0)+rem*w[t]/N[t] if w[t]>0 else 0 for t in range(12)]
def p_design(t):
    m=t//2; pm=comb(5,m)*comb(n-5,5-m)/C
    return pm*(1/B if t%2 else (B-1)/B)
def p_exploit(t):   # ticket picks bonusball b among its own normals
    m=t//2
    pin = comb(4,m-1)*comb(n-5,5-m)/C if m>=1 else 0   # b in S∩W
    pout= comb(4,m)*comb(n-5,5-m)/C                    # b not in W
    return pin*(1/5) if t%2 else pin*(4/5)+pout
ev_d=sum(p_design(t)*pay[t] for t in range(12)); ev_e=sum(p_exploit(t)*pay[t] for t in range(12))
print(f"pool=${pool:,.0f} useMinimums={use_min}")
print(f"Designed EV per $1 ticket: ${ev_d:.3f}   Exploit EV (bonus chosen from own normals): ${ev_e:.3f}")
print(f"Jackpot tier odds: designed 1 in {1/p_design(11):,.0f}, exploit 1 in {1/p_exploit(11):,.0f}; tier-11 payout ${pay[11]:,.0f}")
