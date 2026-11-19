// SPDX-License-Identifier: MIT
pragma solidity 0.8.13;
import "./CrossBase.t.sol";

/// Leads on gHYBR withdraw (cross-check with the gHYBR reviewer):
///  (a) the last holder can never exit: remainingAmount == 0 -> multiSplit reverts "ZW"
///  (b) sanity: a partial withdraw works once splitting is enabled and Team is set
contract GHybrWithdrawTest is CrossBase {
    address team_ = makeAddr("team");

    function setUp() public override {
        super.setUp();
        vm.warp(1_700_000_000);
        votingEscrow.toggleSplit(address(gHybr), true);
        gHybr.setTeam(team_);
        vm.startPrank(alice);
        hybr.approve(address(gHybr), type(uint256).max);
        gHybr.deposit(1_000e18, alice);
        vm.stopPrank();
    }

    function _toWithdrawWindow() internal {
        warpToNextEpoch(gHybr.head_not_withdraw_time() + 1);
    }

    function test_lastHolderCannotWithdrawEverything() public {
        _toWithdrawWindow();
        uint256 all = gHybr.balanceOf(alice);
        vm.prank(alice);
        vm.expectRevert(bytes("ZW"));
        gHybr.withdraw(all);
    }

    function test_partialWithdrawWorks() public {
        _toWithdrawWindow();
        vm.prank(alice);
        uint256 id = gHybr.withdraw(500e18);
        assertEq(votingEscrow.ownerOf(id), alice);
    }
}
