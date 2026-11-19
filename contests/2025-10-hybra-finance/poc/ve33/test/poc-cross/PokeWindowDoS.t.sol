// SPDX-License-Identifier: MIT
pragma solidity 0.8.13;
import "./CrossBase.t.sol";

/// Lead (fork delta): Hybra routes every gauge reward claim through RewardHYBR. TO_HYBR sends the penalty to
/// gHYBR.receivePenaltyReward -> VotingEscrow.deposit_for(gHYBR's veNFT) -> Voter.poke() when voted.
/// poke() reverts "DW" during the first NO_VOTING_WINDOW of every epoch, so while gHYBR's veNFT has an
/// active vote, all TO_HYBR / TO_GHYBR redemptions (and gHYBR deposits) revert in that window.
contract PokeWindowDoSTest is CrossBase {
    function _gHybrVotes() internal {
        vm.warp(1_700_000_000);
        vm.startPrank(alice);
        hybr.approve(address(gHybr), type(uint256).max);
        gHybr.deposit(1_000e18, alice);
        vm.stopPrank();

        warpToNextEpoch(301); // inside voting window
        address[] memory pools = new address[](1); pools[0] = pair;
        uint256[] memory w = new uint256[](1); w[0] = 1;
        gHybr.vote(pools, w); // operator = deployer
        assertTrue(votingEscrow.voted(gHybr.veTokenId()));
    }

    function _bobHasRHybr(uint256 amt) internal {
        vm.startPrank(bob);
        hybr.approve(address(rewardHybr), type(uint256).max);
        rewardHybr.depostionEmissionsToken(amt); // same call a gauge makes before redeemFor
        vm.stopPrank();
    }

    function test_redeemToHybrRevertsInNoVotingWindow() public {
        _gHybrVotes();
        _bobHasRHybr(100e18);

        warpToNextEpoch(10); // first seconds of the new epoch
        vm.prank(bob);
        vm.expectRevert(bytes("DW"));
        rewardHybr.redeem(100e18, 0); // TO_HYBR

        vm.prank(bob);
        vm.expectRevert(bytes("DW"));
        rewardHybr.redeem(100e18, 2); // TO_GHYBR

        vm.prank(alice);
        vm.expectRevert(bytes("DW"));
        gHybr.deposit(1e18, alice);

        // after the window it works again
        vm.warp(epochStart() + 301);
        vm.prank(bob);
        rewardHybr.redeem(100e18, 0);
    }

    /// Control: without gHYBR voting, the same redemption works at epoch start.
    function test_control_noVoteNoRevert() public {
        vm.startPrank(alice);
        hybr.approve(address(gHybr), type(uint256).max);
        gHybr.deposit(1_000e18, alice);
        vm.stopPrank();
        _bobHasRHybr(100e18);
        warpToNextEpoch(10);
        vm.prank(bob);
        rewardHybr.redeem(100e18, 0);
    }
}
