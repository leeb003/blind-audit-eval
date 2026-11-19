# Hybra Finance (2025-10-hybra-finance)

- Contest: https://code4rena.com/audits/2025-10-hybra-finance
- Code: https://github.com/code-423n4/2025-10-hybra-finance at commit `17d72f0b95e6`
- Official report (opened only after grading): https://code4rena.com/reports/2025-10-hybra-finance
- Scope: 5,868 lines across the 14 files in scope.txt (ve33 + cl)
- Findings log, blind prediction, and scorecard: [NOTES.md](NOTES.md)

## Running the proofs

Clone the contest repository at the commit above, copy the folders under `poc/` into it at the paths shown, then:

```
cd ve33 && forge test                                        # solc 0.8.13; poc dirs -> ve33/test/
cd ../cl && FOUNDRY_DYNAMIC_TEST_LINKING=false forge test     # solc 0.7.6 (no PoCs here; CL findings are tested from ve33)
```
