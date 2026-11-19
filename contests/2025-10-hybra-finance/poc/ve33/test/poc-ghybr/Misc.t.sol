// SPDX-License-Identifier: MIT
pragma solidity 0.8.13;

import "./GHybrBase.t.sol";

contract GHybrMiscTest is GHybrBase {
    /// Lead: withdraw requires voted(veTokenId)==false; the voted flag persists across epochs until reset,
    /// so while gHYBR keeps its votes (normal yield operation) no holder can withdraw in any epoch.
    function test_withdrawBlockedWhileGHybrVoted() public {
        dep(alice, 1000e18);
        uint256 id = gHybr.veTokenId();
        vm.prank(address(voter));
        votingEscrow.voting(id); // what VoterV3.vote does
        for (uint256 i; i < 3; i++) {
            vm.warp(block.timestamp + 1 days);
            toWithdrawWindow();
            vm.prank(alice);
            vm.expectRevert(bytes("Cannot withdraw yet"));
            gHybr.withdraw(100e18);
        }
    }

    /// Lead: deposit_for on a voted veNFT calls Voter.poke, which reverts ("DW") in the first
    /// NO_VOTING_WINDOW of every epoch -> gHYBR deposits, rHYBR TO_HYBR / TO_GHYBR redemptions
    /// (and so gauge getReward with those types) revert in that window.
    function test_voteWindowBlocksRewardRedemptions() public {
        dep(alice, 1000e18);
        uint256 id = gHybr.veTokenId();
        vm.prank(address(voter));
        votingEscrow.voting(id);
        vm.warp(HybraTimeLibrary.epochNext(block.timestamp) + 10); // inside no-voting window
        vm.startPrank(bob);
        hybr.approve(address(rewardHybr), 1000e18);
        rewardHybr.depostionEmissionsToken(1000e18);
        vm.expectRevert(bytes("DW"));
        rewardHybr.redeem(1000e18, 0); // TO_HYBR -> receivePenaltyReward -> deposit_for -> poke
        vm.expectRevert(bytes("DW"));
        rewardHybr.redeem(1000e18, 2); // TO_GHYBR
        vm.stopPrank();
        // outside the window it works
        vm.warp(block.timestamp + 400);
        vm.prank(bob);
        rewardHybr.redeem(1000e18, 0);
    }

    /// Lead: the last holder can never withdraw all shares: remainingAmount==0 -> multiSplit reverts "ZW".
    function test_lastHolderCannotWithdrawAll() public {
        uint256 s = dep(alice, 1000e18);
        vm.warp(block.timestamp + 1 days);
        toWithdrawWindow();
        vm.prank(alice);
        vm.expectRevert(bytes("ZW"));
        gHybr.withdraw(s);
        vm.prank(alice);
        gHybr.withdraw(s - 1); // works, leaves 1 wei share behind
    }

    /// Lead: tiny withdrawals round the fee to 0 -> multiSplit "ZW" revert (dust only).
    function test_dustWithdrawReverts() public {
        dep(alice, 1000e18);
        vm.warp(block.timestamp + 1 days);
        toWithdrawWindow();
        vm.prank(alice);
        vm.expectRevert(bytes("ZW"));
        gHybr.withdraw(99);
    }

    /// Dismissal check: sandwiching a reward (penalty/rebase) landing is not profitable once the
    /// deposit share bug and 1% withdraw fee apply.
    function test_dismiss_rewardSandwichUnprofitable() public {
        dep(alice, 100_000e18);
        uint256 bobIn = 100_000e18;
        uint256 s = dep(bob, bobIn);
        // reward of 2% of TVL lands (penalty from rHYBR redemptions)
        hybr.transfer(address(gHybr), 4_000e18);
        gHybr.receivePenaltyReward(4_000e18);
        vm.warp(block.timestamp + 1 days);
        toWithdrawWindow();
        vm.prank(bob);
        uint256 nft = gHybr.withdraw(s);
        (int128 amt,,) = votingEscrow.locked(nft);
        assertLt(uint256(int256(amt)), bobIn, "sandwich loses money");
    }

    /// Dismissal check: withdraw bypassing the transfer lock is harmless for price (withdraw is gated by window).
    function test_dismiss_depositWithdrawSameWindowNoGain() public {
        dep(alice, 100_000e18);
        toWithdrawWindow();
        uint256 s = dep(bob, 1000e18);
        vm.prank(bob);
        uint256 nft = gHybr.withdraw(s);
        (int128 amt,,) = votingEscrow.locked(nft);
        assertLt(uint256(int256(amt)), 1000e18);
    }
}
