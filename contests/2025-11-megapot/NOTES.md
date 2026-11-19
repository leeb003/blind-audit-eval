# 2025-11-megapot findings log
Started 2026-09-20. Official report: 3 High / 8 Medium (unread, in spoilers/).
Setup: 1 main pass (Jackpot.sol core) + 3 parallel reviewers (LP, bridge/NFT, payout/randomness).
PoCs: `contests/2025-11-megapot/poc-forge/{core,lp,bridge,payout}/` (Foundry; real submissions needed hardhat PoCs).
Excluded: README known issues, V12 findings, Zellic report.

## Candidates (H/M)

### C-0 Same random seed reused for normals and bonusball draws (payout reviewer) - H ~65%
- ScaledEntropyProvider.sol:271-283 passes the same `uint256(_randomNumber)` to FisherYatesRejection.draw for every set request.
  When bonusballMax == normalBallMax the bonusball is always the first winning normal.
- bonusballMax is derived from pool size; B == 30 when LP value is in ($3.616M, $3.741M] at test params - anyone can steer there with lpDeposit.
- Picking bonusball from your own normals: top tier odds 6x; EV per $1 ticket ~$1.61 vs designed $0.69 -> LPs drained.
- PoCs: payout/ test_bonusballAlwaysEqualsFirstWinningNormal, test_attackerSteersPoolIntoWindowWithLpDeposit, test_rawProviderOutputIdentical
- Fix: per-request seed, e.g. keccak256(abi.encode(randomNumber, i)).

### C-1 Bridge charges global ticketPrice, Jackpot charges drawing ticketPrice (bridge reviewer) - M ~65%
- JackpotBridgeManager.sol:178-184 pulls `jackpot.ticketPrice() * n`; Jackpot.sol:382 charges `drawingState[current].ticketPrice * n`.
  setTicketPrice only changes the global (takes effect next drawing), so they diverge for the rest of the drawing.
- Price up: bridge buyers overpay, excess stranded in bridge (no sweep) + leftover allowance. Price down: all bridge buys revert.
- Stranded USDC stealable by any bridge winner via claimWinnings arbitrary call leaving an allowance (JackpotBridgeManager.sol:349-359).
- PoCs: bridge/ test_priceIncrease_bridgeBuyerOverpays_excessStranded, test_priceDecrease_bridgePurchasesDoS, test_strandedUsdcStolenViaLeftoverApproval

### C-2 Late entropy callback during emergency mode settles a drawing whose tickets were refunded (core) - M ~45%
- scaledEntropyCallback (Jackpot.sol:717) has no noEmergencyMode guard; runJackpot does.
- Stuck drawing -> emergency -> users refund -> delayed callback still settles, crediting refunded revenue as lpEarnings
  (and reserving winnings for burned tickets). PoC: LPs owed 3,000,990 USDC vs 2,999,990 held; last LP's emergency withdraw reverts.
- PoC: core/ test_lateCallbackAfterRefundsCreatesPhantomLpValue
- Weakness: owner can prevent by pointing `entropy` elsewhere before refunds; "emergency not intended to be recoverable".

### C-3 Emergency refunds use live referralFee, not the fee charged (core + bridge reviewer independently) - M/L ~30-40%
- Jackpot.sol:591-592 uses global referralFee; referralFee is the only fee param not snapshotted per drawing (also applies mid-drawing to buys).
- Fee lowered -> over-refund paid from LP funds (100 in, 106.5 out). Fee raised -> users under-refunded, remainder stranded.
- PoCs: core/ test_emergencyRefundUsesLiveReferralFee, test_emergencyRefundUnderpaysAfterFeeIncrease, test_referralFeeChangeAppliesMidDrawing
- Found independently by 3 of 4 passes (core, bridge, LP). LP PoC: lp/ test_referralFeeChange_emergencyRefundDrainsLPs
- Weakness: needs admin change + emergency; known-issue wording on referral refunds might be read as covering it.

### C-4 Replacing payoutCalculator wipes unclaimed winnings of past drawings (core) - M/L ~25%
- claimWinnings (Jackpot.sol:433) reads past drawings' payouts from the *current* calculator; claim burns the ticket first, so winners get 0 permanently.
- Matches sponsor concern #12 ("global param used for a prior drawing"). Weakness: pure admin action.
- Found independently by payout and LP reviewers (3 of 4 passes). Worse mid-drawing: new calculator has no tier info, the running drawing settles with 0 winnings, even a jackpot winner gets nothing.
- PoCs also: lp/ test_swapPayoutCalculator_zeroesPriorWinnings, test_swapPayoutCalculator_midDrawingWinnersGetNothing
- PoC: core/ test_swappingCalculatorWipesUnclaimedWinnings

## QA / Low
- Entropy callback gas exceeds the requested limit at test-suite limits (owner-configured) (payout reviewer)
- Bridged tickets have no emergency refund path (owner can sign claimTickets to recover) (bridge reviewer)

- Referrer win-share from claims made during emergency is stranded in a never-settled drawing (LP reviewer)
- getLPValueBreakdown reverts at currentDrawingId == 0 (view only) (LP reviewer)

## Checked and dismissed (core)
- Ticket id collisions, referral scheme id collisions, self-referral (same cost as any referrer), runJackpot refund reentrancy (guarded),
  tier calc uses per-drawing ballMax (Zellic fix present), referralWinShare snapshotted, duplicate-ticket prize pool top-up vs referral fee (fine at default params).
- Bridge reviewer: signature replay, packed-array collision (V12), NFT theft via arbitrary call, claimTickets reentrancy, NFT index tracking.
- Payout reviewer: winner counting fuzzed vs brute force (500 runs, correct), no over-allocation, bitpacking/tier calc correct,
  Fisher-Yates uniform, callback spoofing fixed (Zellic 3.1), settlement underflow not reachable.
- LP reviewer: LP solvency invariant fuzzed (256 runs x 100 calls, 16 draws, accumulator down to 0.82) - always solvent; every party can
  emergency-exit; no settlement underflow; accumulator reset (Zellic 3.10 fix) safe; no inflation/donation attack; referral>edge only by admin config.

## Blind prediction before grading
Official: 3 H / 8 M. Our candidates: 1 H, 4 M-ish. Guess: C-0 and C-1 match real findings; maybe 1 more. So ~2-3 of 11 found.

## Scorecard (graded 2026-09-20 against the official C4 report)
| Official | Title | Us |
|---|---|---|
| H-01 | Steal ticket NFTs from BridgeManager via claimWinnings arbitrary call | MISSED - bridge reviewer explicitly dismissed it ("NFT moves don't move USDC"). Real trick: approveTo = attacker contract, NFT safeTransferFrom -> onERC721Received pulls exactly the claimed USDC, so the balance check passes. We even found the leftover-approval primitive in C-1 but didn't combine it. |
| H-02 | Subset counting exceeds Base 25M tx gas limit at large bonusballMax -> drawing can't settle | PARTIAL - payout reviewer measured callback gas (L-1) but blamed owner-set limits; missed the hard chain cap. Would have been QA -> $0. |
| H-03 | LP pool cap exceeded on settlement (earnings push past cap -> bitpacking bound) | MISSED - LP reviewer dismissed as "unrealistic". |
| M-01 | Global params changed mid-draw alter result (fee threshold, entropy, calculator, referralFee) | FOUND (C-3, C-4). 70+ duplicates -> tiny payout. |
| M-02 | Bridge uses global ticketPrice -> overpayment | FOUND (C-1) |
| M-03 | Adding liquidity DoSes governance param updates (setLPPoolCap reverts) | MISSED |
| M-04 | lpEarnings (referral win share) created in emergency mode stuck | UNDERCALLED - LP reviewer had it as Low #3. |
| M-05 | Same seed for normals + bonusball | FOUND (C-0). We guessed High; judged Medium. Only 2 other finders -> best-paying of ours. |
| M-06 | Changing Pyth provider lets attacker fix result | MISSED |
| M-07 | Changing entropy provider mid-drawing -> permanent lock | MISSED - core pass considered setEntropy-while-locked and wrongly judged it recoverable. |
| M-08 | Changing payout calculator mid-drawing loses winnings | FOUND (C-4) |

Our C-2 (late callback during emergency) is not in the report.

| | Count |
|---|---|
| H/M clearly found | 4 of 11 (M-01, M-02, M-05, M-08) |
| Found but under-rated (would pay $0) | 2 (H-02, M-04) |
| Missed | 5 (H-01, H-03, M-03, M-06, M-07) |
| All 3 Highs | 0 found |

Lessons:
- Two misses were leads we *had* and talked ourselves out of (H-01, M-07). Rule: "dismissed" leads need a PoC attempt too, not reasoning.
- Severity calibration: we under-rated chain-level constraints (Base gas cap) and emergency-mode leftovers.
- Arbitrary external calls: always try callbacks (ERC721/1155 receivers, hooks) to satisfy balance checks.
- Popular admin-param findings (M-01) pay little; unique technical ones (M-05) pay most.
