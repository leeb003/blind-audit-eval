# 2025-11-sukukfi findings log
Started 2026-09-20 with PROCESS.md v2. Official report: 1 H / 3 M (unread, in spoilers/).
Reviewers: vault (async ERC7575), share token, settlement layer (WERC7575), cross-cutting + skeptic.
Repo tests: 573/574 pass before our changes.

## Candidates
### S-1 Anyone can redeem/withdraw another user's shares in WERC7575Vault (settlement) - H, ~55% (V12 overlap risk)
- WERC7575Vault.sol:397-411 `_withdraw` has no msg.sender==owner / allowance check; only gate is spendSelfAllowance(owner) (WERC7575ShareToken.sol:660), which every transfer-capable user has.
- PoCs: poc-settle/ test_anyoneCanRedeemVictimSharesToThemselves (100k USDC), test_anyoneCanWithdrawUpToVictimSelfAllowance, test_onlyGateIsVictimSelfAllowance
- Share-token reviewer hit the same root cause independently: anyone can redeem the ShareToken's ENTIRE investment position
  (ShareToken holds WERC self-allowance for withdrawFromInvestment). PoC: poc-share/ test_L3_anyoneDrainsShareTokenInvestmentPosition
- Risk: V12 "Incorrect allowance spending in spendSelfAllowance" touches same code; judge may call it known.

### S-2 1-wei donation permanently blocks unregisterVault (settlement) - M/L ~35%
- WERC7575ShareToken.sol:265-279 requires totalAssets()==0 && balanceOf(vault)==0; no sweep; one vault per asset. PoC: test_L2_dustDonationBlocksUnregisterVault

### S-3 fulfillRedeem while assets are invested: totalAssets() floors at 0, NAV double-counts -> insolvency (vault) - M/H ~45%
- ERC7575VaultUpgradeable.sol:1174-1179 `balance > reserved ? balance - reserved : 0`; fulfillRedeem (:822-840) reserves without checking idle balance.
  Invested value still counted via ShareToken._calculateInvestmentAssets while redeemed shares leave supply.
- PoC: Alice+Bob 10k each, all invested, Alice's redeem fulfilled -> Bob's shares worth 20k; claims 30k vs 20k real. Later claimant reverts.
- PoCs: poc-vault/ test_fulfillRedeemAfterInvestInflatesSharePrice, test_newDepositorsDilutedDuringWindow
- Independently found by cross-cutting reviewer too (poc-cross/ ReservedClamp.t.sol) - 2 of 4.
- Weakness: needs Investment Manager ordering (trusted role; "admin mistakes invalid"); known issue "Reserved Assets Not Invested" is adjacent but about idle yield.

### S-2b Any user can permanently block ShareTokenUpgradeable.unregisterVault (cross) - M ~35%
- Requires activeDepositRequestersCount==0 (ShareTokenUpgradeable.sol:304); a controller leaves only after claiming all; only controller/operator can claim.
  Also asset.balanceOf(vault)==0 (:318) with no sweep -> 1 wei donation blocks. One vault per asset -> never replaceable.
- PoCs: poc-cross/ test_unclaimedDepositBlocksUnregisterForever, test_oneWeiDonationBlocksUnregister. Same class as S-2 (settlement layer).

### S-4 unregisterVault checks bypassable via desynced active-requester sets (share) - L/M ~35%
- redeem/withdraw/deposit/cancel remove controller from active sets while pending amounts remain (ERC7575VaultUpgradeable.sol:575, 901, 943, 1592, 1761);
  unregisterVault (ShareTokenUpgradeable.sol:86-117) relies on those counts -> vault unregistered with pending redeems -> later fulfilled redeems unclaimable.
- PoCs: poc-share/ test_L2_unregisterWithPendingRedeemSharesBricksRedeem (+ control), test_L1_* (set desync)

## QA
- Redeem with 0 claimable assets deletes entry but decrements totals only by burned shares -> phantom claimable shares (vault)
- withdrawFromInvestment(max) overflows for <18-decimal assets (vault)
- setInvestmentVault only checks asset; other share token hides investments from NAV (admin) (vault)
- Operators shared across vaults; unregistered vault keeps investment approval; storage slot not ERC-7201 formula (share)
- pause() doesn't halt batchTransfers/rBatchTransfers/adjustrBalance/permit despite natspec (partly V12)
- transferFrom with caller==from spends self-allowance twice

## Skeptic pass (cross-cutting reviewer)
- Confirmed S-1 (all 3 tests), S-2; rated pause-bypass QA, active-set desync Low, withdrawAll overflow + setInvestmentVault QA.
- Dismissed with tests: upgrade path works/owner-only, initializers locked, no slot collisions, rounding round-trips (6/8/18 dec, 256 runs),
  cross-asset arb, donation inflation, hook-token reentrancy, fee-on-transfer reverts, role boundaries.

## Blind prediction before grading
Official: 1 H / 3 M. Ours: S-1 (H), S-3 (M/H), S-2/S-2b (M), S-4 (L/M).
Guess: the H is S-1 or S-3 (S-1 at risk of being ruled V12-known). Expect 2 of 4 found.

## Scorecard (graded 2026-09-20 against the official C4 report)
| Official | Title | Us |
|---|---|---|
| H-01 | Missing authorization check in WERC7575Vault withdraw/redeem | FOUND (S-1) - exact root cause. ~150 duplicates -> small payout. |
| M-01 | Unregistering vaults can be DoSed (both share tokens) | FOUND (S-2 + S-2b, both contracts, same as report). ~90 duplicates. |
| M-02 | Stale redemption liabilities: price fixed at fulfill, losses afterwards leveraged onto remaining holders + DoS | MISSED |
| M-03 | fulfillRedeem max(0, ...) clamp inflates share price, over-redemption | FOUND (S-3) - exact root cause and same Alice/Bob scenario. 11 finders -> best-paying of ours. |

| | Count |
|---|---|
| H/M found | **3 of 4** (incl. the only High) |
| Missed | 1 (M-02) |
| Severity calls | S-1 H (correct), S-3 M/H (M), S-2 M/L (M) - all would have paid |

Why M-02 was missed: no reviewer modelled the investment *losing* value between fulfillRedeem and claim.
Process fix: for async flows, simulate price moves (up AND down) between every step (request -> fulfill -> claim).
