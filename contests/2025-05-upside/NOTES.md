# 2025-05-upside findings log
Started 2026-09-20. First pass by Claude done same day (~1h wall clock).
Scope: UpsideProtocol.sol, UpsideMetaCoin.sol (379 nSLOC). Prior audit (Hans) + README known issues read and excluded.
PoCs: `contests/2025-05-upside/poc/` -> run `forge test` (all pass, offline).

## Submit-worthy candidates

### M-1 (uncertain) Changing the staking contract breaks all pre-existing MetaCoins
- `setStakingContractAddress()` points sells at the new staking contract, but coins created earlier were never
  whitelisted there, so `distributeRewards()` reverts with TokenNotWhitelisted and **every sell of an old coin reverts**.
  The USDC backing those coins is locked.
- UpsideProtocol has no function to whitelist existing coins on the staking contract, and the staking contract must be
  owned by the protocol (tokenize() calls its onlyOwner function), so the owner can't whitelist them directly either.
- Realistic trigger: the codebase ships a stub "if the decision is not to enable staking just yet", so a stub -> staking
  migration is the planned path.
- Also: stakers in the old staking contract can't unstake/claim, because the old contract loses its implicit
  transfer whitelist (`metaCoinWhitelist` only whitelists the *current* stakingContractAddress).
- PoC: `test_coinsFromBeforeMigrationCannotBeSold`, `test_stakersInOldContractAreStuck`
- **Weakness:** workaround exists (`test_workaround_deployAsEoaWhitelistThenHandOver`): deploy staking owned by the
  EOA, whitelist old coins, transfer ownership to protocol. Old stakers can be fixed via setMetaCoinWhitelist.
  Judges could call it admin error -> QA. My honest odds it survives as Medium: ~30-40%.
- Fix: add an owner function on UpsideProtocol that calls whitelistStakingToken for a list of existing coins, and
  keep old staking contracts whitelisted (or migrate balances).

## QA / Low
- L-1 Swaps stay enabled after withdrawLiquidity(); buys return 0 MetaCoin and take the user's USDC + fee (if
  minOut=0), and the owner can sweep it again right away since the timer never resets. (`test_buyAfterWithdrawReturnsNothing`)
  Partly covered by the known "global timer" issue.
- L-2 URL uniqueness only by exact string: trailing slash, case, twitter.com vs x.com all tokenize separately.
  Breaks the stated "tokenize once" invariant in spirit. (`test_sameUrlTokenizedTwice`)
- L-3 swap() has no deadline parameter.
- L-4 Swaps divide by zero until setFeeInfo() is called (deployment ordering). (`test_swapRevertsBeforeFeeInfoSet`)
  Close to the prior audit's informational - probably excluded.
- L-5 Custom transferFrom decrements infinite (max) allowances, unlike OZ. (`test_infiniteAllowanceDecrements`)
- L-6 Fee rounds to 0 for dust amounts (e.g. 1 unit at 99% fee). Not economically exploitable.
- L-7 tokenize() can be front-run to capture deployer fees for a hot URL (Base has a private sequencer, so weak).

## Checked and dismissed
- Solvency: fuzzed 128k random buys/sells/claims across 2 coins - USDC and MetaCoin always fully backed,
  supply fixed, sells only ever revert at the reserve floor. (`poc/Invariants.t.sol`)
- Reentrancy on swap(): trusted-token assumption is a known issue.
- metaCoinInfoMap interface returns a struct vs. getter's tuple: ABI-identical for all-static structs. Fine.
- Whitelist bypass via staking (stake/unstake/claim only pay msg.sender) or leftover protocol allowances
  (approve is exact each sell). None found.
- Divide-before-multiply (Slither): harmless, fee bp math.
- distributeRewards with zero stakers: handled (goes to protocol fees).
- Out of scope but noted: staking rewards can be sandwiched (stake before a big sell, claim, unstake).

## Blind prediction before grading
Likely the real report has 1-3 Mediums. Guess: we caught 0-1 of them.

## Scorecard (graded 2026-09-20 against the official C4 report)
Official result: **0 High, 0 Medium.** 27 QA reports; HM pool paid $0, QA pool $400 split across 27.
Top-ranked QA report (Brene) highlighted 3 issues:
| Official QA issue | Us |
|---|---|
| Front-running tokenize() | found (L-7) |
| Swap fee bypass via small amounts | found (L-6) |
| tokenizeFeeDestinationAddress not updated when ownership transfers | missed (weak issue) |

| | Count |
|---|---|
| Real H/M we found | 0 of 0 |
| Real H/M we missed | 0 |
| Our M candidate | not in report; per rules a Medium downgraded to QA earns $0 - likely outcome |
| Highlighted QA issues we matched | 2 of 3 |

Lessons: our pass matched the field on a small, clean codebase. Contests this small pay almost nothing.
Next practice target should be larger/more complex (e.g. brix-money or megapot) where real Mediums exist.
The findings repo is private/gone, so we can't see whether anyone submitted the staking-migration issue.
