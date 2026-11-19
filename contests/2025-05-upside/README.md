# Upside (2025-05-upside)

- Contest: https://code4rena.com/audits/2025-05-upside
- Code: https://github.com/code-423n4/2025-05-upside at commit `daabd0ca1bca`
- Official report (opened only after grading): https://code4rena.com/reports/2025-05-upside
- Scope: 379 lines, see out_of_scope.txt in the contest repo
- Findings log, blind prediction, and scorecard: [NOTES.md](NOTES.md)

## Running the proofs

Clone the contest repository at the commit above, copy the folders under `poc/` into it at the paths shown, then:

```
npm install              # then pin @openzeppelin/contracts to 5.3.0 (newer breaks with evm=paris)
forge test               # poc/ -> contests/2025-05-upside/poc/ ; offline
```
