// SPDX-License-Identifier: MIT
pragma solidity 0.8.13;

import "forge-std/Test.sol";
import {C4PoCTestbed} from "../C4PoCTestbed.t.sol";

/// Lead: GrowthHYBR.deposit() locks the HYBR (deposit_for) BEFORE calculateShares(), so totalAssets()
/// already includes the new amount -> depositor gets amount*S/(A+amount) instead of amount*S/A.
contract GHybrDepositTest is C4PoCTestbed {
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    function setUp() public override {
        super.setUp();
        hybr.transfer(alice, 1_000e18);
        hybr.transfer(bob, 1_000e18);
    }

    function test_secondDepositorIsDiluted() public {
        vm.startPrank(alice);
        hybr.approve(address(gHybr), type(uint256).max);
        gHybr.deposit(100e18, alice);
        vm.stopPrank();
        assertEq(gHybr.balanceOf(alice), 100e18);
        assertEq(gHybr.totalAssets(), 100e18);

        vm.startPrank(bob);
        hybr.approve(address(gHybr), type(uint256).max);
        gHybr.deposit(100e18, bob);
        vm.stopPrank();

        // fair: bob should get 100e18 shares (same price). Actual: 100*100/200 = 50
        emit log_named_decimal_uint("bob shares", gHybr.balanceOf(bob), 18);
        emit log_named_decimal_uint("bob claimable HYBR", gHybr.calculateAssets(gHybr.balanceOf(bob)), 18);
        emit log_named_decimal_uint("alice claimable HYBR", gHybr.calculateAssets(gHybr.balanceOf(alice)), 18);
        assertEq(gHybr.balanceOf(bob), 50e18);
        // bob deposited 100 but can claim ~66.67; alice deposited 100 and can claim ~133.33
        assertApproxEqAbs(gHybr.calculateAssets(gHybr.balanceOf(bob)), 66.666666666666666666e18, 1e3);
    }

    /// Same dilution hits every gauge reward redeemed TO_GHYBR through RewardHYBR (redeemType 2).
    function test_rewardRedeemToGHybrAlsoDiluted() public {
        vm.startPrank(alice);
        hybr.approve(address(gHybr), type(uint256).max);
        gHybr.deposit(1_000e18, alice);
        vm.stopPrank();

        // bob converts 1000 HYBR worth of rHYBR into gHYBR (as a gauge would on his behalf)
        rewardHybr.addExempt(bob);
        vm.startPrank(bob);
        hybr.approve(address(rewardHybr), type(uint256).max);
        rewardHybr.depostionEmissionsToken(1_000e18);
        rewardHybr.redeem(1_000e18, 2);
        vm.stopPrank();
        assertEq(gHybr.balanceOf(bob), 500e18, "bob gets half the fair shares");
    }
}
