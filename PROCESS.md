# Audit process (v2, after Upside + Megapot)

## 0. Pick & isolate
- Report must exist with H/M > 0. Read ONLY the count line; save report to spoilers/<contest>/ unread.
- Quarantine anything added after the contest end date (Discord exports, findings links).
- Known issues = README + bot/V12 reports + prior audits. Read them before hunting.

## 1. Map
- Read README areas of concern + invariants; turn each into a checklist item that must end as PROVEN / DISPROVEN-WITH-TEST / OUT-OF-SCOPE.
- Split codebase into areas; one reviewer per area + one cross-cutting reviewer.

## 2. Hunt (per reviewer)
- **Smoke every external/public function** at least once in the harness with realistic state; a function that always reverts is a finding (Hybra M-07).
- Every lead is logged. **A lead is only dismissed after a test attempt**, not by reasoning. (Megapot: H-01 and M-07 were dismissed by reasoning.)
- Mandatory checklists:
  - **Arbitrary/external calls:** try callbacks to satisfy balance checks (ERC721/1155 onReceived, ERC777, hooks, fallback),
    leftover approvals, calling other protocol contracts (NFT, token, self) as the target.
  - **Admin setters:** for EVERY setter, what happens if it changes (a) mid-drawing/epoch, (b) while a request/callback is pending,
    (c) with past unclaimed state outstanding? Which reads use the global instead of a snapshot?
  - **External dependency swaps:** changing oracle/entropy/provider addresses mid-flight; who can influence the new provider's output?
  - **Chain limits:** tx gas cap (Base 25M, Arbitrum 32M, mainnet ~30-36M block), callback gas limits, calldata size. Measure worst-case gas
    at the *max* parameters the protocol allows (pool caps etc.), not test defaults.
  - **Caps & bounds:** can any cap be exceeded by earnings/interest/rounding rather than deposits? What breaks downstream if it is?
  - **Emergency / pause modes:** which functions still run? What value is created/stranded while in that mode?
  - **Async / multi-step flows:** simulate price moves up AND down (investment gains/losses) between every step
    (request -> fulfill -> claim); who bears the loss if value changes after a price is locked in? (SukukFi M-02 miss)
  - **Dust / griefing inputs:** dust votes, dust deposits, 1-wei positions in any per-user loop or check (poke, reset, withdraw) (Hybra M-04).
  - **Governance DoS:** can users make admin setters revert (e.g. push totals above a new cap)?

## 3. Severity calibration
- DoS of core flow / permanent lock of funds -> usually H or M, even if "only" a param or chain limit triggers it.
- Stuck value in an unrecoverable mode -> M, not L.
- Pure admin misconfiguration with no user trigger -> usually QA; admin *routine* action with harmful side-effect -> often M.
- Findings with many obvious duplicates pay little; prioritise depth on unique technical issues.

## 4. Verify & grade
- Bot/AI reports (V12 etc.) published *mid-contest* may not be enforced by judges; log those overlaps separately instead of dropping them.
- Every H/M candidate has a passing PoC. Cross-check other reviewers' dismissals.
- Write blind prediction, then grade against the report; record misses + root cause of each miss.
