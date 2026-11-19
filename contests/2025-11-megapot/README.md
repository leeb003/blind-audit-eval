# Megapot (2025-11-megapot)

- Contest: https://code4rena.com/audits/2025-11-megapot
- Code: https://github.com/code-423n4/2025-11-megapot at commit `538649e8a05b`
- Official report (opened only after grading): https://code4rena.com/reports/2025-11-megapot
- Scope: 1,709 lines
- Findings log, blind prediction, and scorecard: [NOTES.md](NOTES.md)

## Running the proofs

Clone the contest repository at the commit above, copy the folders under `poc/` into it at the paths shown, then:

```
forge test               # poc-forge/{core,lp,bridge,payout} -> contests/2025-11-megapot/poc-forge/
# the sponsor's own suite: yarn install --ignore-engines && npx hardhat test test/*.spec.ts test/lib/*.ts test/e2e/*.ts
```
