# 2025-10-hybra-finance findings log
Started 2026-09-20 with PROCESS.md v2.1. Official report: 1 H / 9 M (unread, in spoilers/).
Fork of Blackhole. Known: README list, PeckShield, V12, Blackhole acknowledged findings.
Reviewers: VotingEscrow, gHYBR/RewardHYBR/swapper, Voter/Gauges/Minter, CL pool + CL gauge, cross-cutting (fork delta + skeptic).

## Candidates
### Y-1 gHYBR mints shares AFTER deposit_for inflates totalAssets -> every later depositor underpaid (ghybr) - H ~75%
- GovernanceHYBR.sol deposit(): deposit_for (L137) then calculateShares(amount) (L144) uses totalAssets() that already includes amount.
- 2x1000 deposits: 2nd gets 500 shares (~667 HYBR); 1-wei first deposit -> later deposits mint 0; rHYBR->gHYBR "1:1" redemptions underpaid.
- PoCs: ve33/test/poc-ghybr/ test_secondDepositorGetsHalfTheShares, test_whaleExtractsValueFromLaterDepositors, test_rewardRedemptionToGHybrUnderpaid, test_oneWeiFirstDepositMakesLaterDepositsMintZero
- Verified by me: ordering confirmed in source, 10/10 tests pass. Cross reviewer found it independently (poc-cross/GHybrDeposit.t.sol).

### Y-2 gHYBR withdrawals blocked while its veNFT has active votes (ghybr) - M/L ~30%
- withdraw() requires !voted(veTokenId); flag persists across epochs until operator reset(). PoC: test_withdrawBlockedWhileGHybrVoted

### Y-7 Reward claims AND GaugeCL withdrawals revert during every epoch's no-vote window (ghybr + cross + ve) - M/L ~40%
- RewardHYBR.redeemFor TO_HYBR -> gHYBR.receivePenaltyReward -> VE.deposit_for (VotingEscrow.sol:821-835) -> Voter.poke reverts "DW" while
  timestamp <= epochVoteStart (VoterV3.sol:158-162). TO_GHYBR -> gHYBR.deposit same. GaugeCL.withdraw force-claims -> reverts;
  only escape is redeemType 1 (forced 2-year lock). Hybra's reward routing turns Blackhole's poke behaviour into a DoS.
- PoCs: poc-cross/ PokeWindowDoS.t.sol, CLWithdrawWindow.t.sol; poc-ghybr/ test_voteWindowBlocksRewardRedemptions; poc-ve/ PokeWindow.t.sol
- Also RewardsDistributor.claim reverts for voted NFTs in window (ve).

### Y-8 Same-timestamp checkpoints: lookups return stale point -> attacker steals weekly rebase (ve) - H ~60%
- VotingEscrow._checkpoint (VotingEscrow.sol:686-737, user points :760-765) appends a new point even when one exists for block.timestamp;
  VotingBalanceLogic.getPast*PointIndex binary search returns first ts match (older point).
- RewardsDistributor._claim (RewardsDistributor.sol:148/181): dummy lock + real lock at weekEnd-1 -> supply lookup stale, balance lookup fresh
  -> attacker (entitled 50%) claims 999/1000; honest claim then underflows. Also votes record too-low weight.
- PoCs: ve33/test/poc-ve/ RebaseSteal.t.sol (+ control fair split), SameBlockPoints.t.sol
- Fix: overwrite point when ts == block.timestamp (Velodrome v2).

## QA / Low
- Merge/multiSplit burn source NFT -> its unclaimed bribes orphaned; worse via gHYBR.withdraw multiSplit (ve)
- multiSplit rounding dust locked in VE forever (ve)
- Hybra removed Blackhole's epochVoteEnd guard -> any NFT can vote in final seconds (cross)
- Last gHYBR holder can't withdraw last wei; dust withdrawals revert ("ZW"); withdraw needs canSplit + Team configured (ghybr)

### Y-3 Votes/resets change gauge weights without checkpointing gauges -> emissions mis-allocated, distributeAll bricked, emissions stranded (voter) - H/M ~45%
- VoterV3._vote/_reset (VoterV3.sol:138-228) change weights/totalWeight without GaugeManager._updateForAfterDistribution (GaugeManager.sol:373);
  notifyRewardAmount (:268) indexes with notify-time weights, distribution uses distribution-time weights. Thena checkpoints first.
- Weight up after notify -> gauge over-claims, its distribute reverts, distributeAll reverts permanently. Reset after notify -> share stranded (1.23M HYBR in PoC).
- Trigger: vote/reset between vote-window open (+300s) and full distribution (batched/late keepers).
- PoCs: ve33/test/poc-voter/ test_newVoteAfterNotifyOverAllocatesAndBricksDistribution, test_resetAfterNotifyStrandsEmissions (+ sanity). Verified 8/8 pass.

### Y-4 Emissions notified while totalWeight == 0 stuck forever in GaugeManager (voter) - L/M ~30%
- GaugeManager.notifyRewardAmount: `if(totalWeight > 0)` else tokens never indexed, no recovery. PoC: test_emissionsWithNoVotesAreStranded (2.47M HYBR)

### Lead: HybraTimeLibrary.WEEK = 1800 (30 min) with 7-day value commented out (libraries/HybraTimeLibrary.sol:7)
- Library not in scope.txt, but all in-scope epoch logic uses it. Possible M ("function incorrect"), judge-dependent.

## QA (voter)
- Vote weight never decays; expired locks keep full weight; only owner/VE can poke
- _setExternalBribe emits wrong old value; setNewBribes doesn't update GaugeV2.internal_bribe; admin swaps of voter/gaugeManager strand emissions

### Y-5 GaugeCL._claimFees counts entire token balance as fees -> anyone sweeps HYBR-pool emissions into bribes; stakers can't withdraw (clgauge) - H ~60%
- GaugeCL.sol:309-315 calls clPool.collectFees() then uses balanceOf(this) for both tokens; reward token is HYBR, so for HYBR pools the undistributed
  emissions are swept as "fees". Upstream CLGauge and Hybra's own GaugeV2._claimFees (GaugeV2.sol:387) use returned amounts.
- withdraw() -> _getReward underflows -> NFT stuck until next notify (then sweepable again). 700k HYBR swept in PoC.
- PoCs: ve33/test/poc-clgauge/ ClaimFeesSweep.t.sol (+ sanity control). Verified 14/14 pass.

### Y-6 DynamicSwapFeeModule caps raised to 50% "anti-MEV", but CLFactory falls back to tickSpacing fee above 10% (clgauge) - M/QA ~35%
- DynamicSwapFeeModule.sol:18,26 MAX_*=500_000; CLFactory.sol:183 `if (fee <= 100_000) return fee;` else default. 30% launch fee -> 0.05%; fee non-monotonic.
- PoC: FeeCapMismatch.t.sol test_launchFeeAbove10PercentFallsBackToBaseFee

## QA (CL)
- GaugeCL has no emergency withdraw; withdraw is isNotEmergency -> staked NFTs frozen in emergency
- Pools created before CLFactory.setGaugeManager can never get a gauge
- earned() view requires msg.sender==staker
- Testbed bug: CLContractsImporter uint80(1)<<176 == 0 -> NFPM _nextPoolId 0 (fixed in PoC base via vm.store)

## Skeptic notes (cross)
- Y-3 (voter checkpoint) confirmed: inherited from Blackhole but not in Blackhole's report -> eligible. Strong H/M.
- Y-5 (CL fee sweep) confirmed strong H/M. Y-6 Hybra-introduced, M/L.
- poc-ve: some tests failing/unfinished at time of skeptic pass (mergePermanent dismissal disproved by cross's trace; rebase-steal not proven).
- WEEK=1800: QA or M at best. Y-2 withdrawBlockedWhileVoted looks like design -> QA.

All 63 PoC tests re-run by coordinator: pass (ve 18, ghybr 10, voter 8, clgauge 14, cross 13).

## Blind prediction before grading
Official: 1 H / 9 M. Our H/M candidates: Y-1, Y-5, Y-8 (H-ish), Y-3 (H/M), Y-7, Y-6, Y-4, Y-2, WEEK constant (M-ish).
Guess: the H is Y-1 or Y-5. Expect ~4-5 of 10 found.

## Scorecard (graded 2026-09-21 against the official C4 report)
| Official | Title | Us |
|---|---|---|
| H-01 | gHYBR deposits before calculating shares | FOUND (Y-1), called High correctly |
| M-01 | CLFactory ignores dynamic fees >10% | FOUND (Y-6) |
| M-02 | GaugeV2 emergencyWithdraw loses accrued rewards | EXCLUDED by rule (V12) - voter reviewer even measured the redistribution but judged "not insolvency" |
| M-03 | gHYBR first-depositor / 0-shares attack | FOUND (Y-1's 1-wei -> 0 shares PoC) |
| M-04 | Dust vote on one pool prevents poke() | MISSED |
| M-05 | GaugeCL rollover lost in rewardRate | EXCLUDED by rule (V12) |
| M-06 | ClaimFees steals staking rewards | FOUND (Y-5) |
| M-07 | gHYBR claimRewards always reverts (poolVote mapping getter misuse) | MISSED |
| M-08 | Same-tx create_lock + increase_amount -> wrong voting power | FOUND (Y-8 root cause; we escalated to rebase theft) |
| M-09 | CL gauge accepts unverified pools | EXCLUDED by rule (V12) |

| | Count |
|---|---|
| Found | **5 of 10** (incl. the High) |
| Excluded because README said V12 = ineligible, but judges paid them | 3 (M-02, M-05, M-09) |
| Genuinely missed | 2 (M-04, M-07) |
| Of issues eligible per README (7) | **5 of 7** |
| Our candidates not in report | Y-3 voter checkpoint, Y-7 vote-window DoS, Y-4 zero-weight emissions, WEEK constant |

Lessons:
- M-07: a function that ALWAYS reverts. Nobody called gHYBR.claimRewards once. Add: smoke-call every external function in the harness.
- M-04: dust votes / minimum-amount griefing on any per-user loop or check (poke, reset). Add to checklist.
- V12 was published mid-contest and judges still paid V12-overlapping issues. For grading: count separately. For live contests: follow the README,
  but if a bot report lands after you've already found something, submit it anyway - early submitters got credit here.
