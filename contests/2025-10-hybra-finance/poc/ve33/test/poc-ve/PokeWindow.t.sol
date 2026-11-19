// SPDX-License-Identifier: MIT
pragma solidity 0.8.13;

import "./VeBase.t.sol";

/// Lead: every VE entry point that adds value to a voted veNFT (deposit_for, increase_amount, increase_unlock_time,
/// merge into it, lockPermanent) unconditionally calls Voter.poke(), and poke() reverts "DW" during the first
/// NO_VOTING_WINDOW seconds of each epoch. Downstream this blocks rHYBR redemptions (both HYBR and gHYBR routes go
/// through gHYBR -> deposit_for on gHYBR's voted veNFT), gHYBR deposits, and RewardsDistributor.claim.
contract PokeWindowTest is VeBase {
    function setUp() public override {
        super.setUp();
        _setupGauge();
    }

    function test_sanity_voteWorks() public {
        uint256 id = _lock(alice, 1000e18, MAXTIME);
        _toVoteWindow();
        _vote(alice, id);
        assertTrue(votingEscrow.voted(id));
        assertGt(voter.weights(pool), 0);
    }

    function test_depositForVotedNftRevertsInNoVotingWindow() public {
        uint256 id = _lock(alice, 1000e18, MAXTIME);
        _toVoteWindow();
        _vote(alice, id);

        // next epoch, inside the first NO_VOTING_WINDOW seconds
        vm.warp(HybraTimeLibrary.epochNext(block.timestamp) + 10);

        vm.prank(bob);
        vm.expectRevert(bytes("DW"));
        votingEscrow.deposit_for(id, 1e18);

        vm.prank(alice);
        vm.expectRevert(bytes("DW"));
        votingEscrow.increase_amount(id, 1e18);

        // a fresh lock merged into the voted one also reverts
        uint256 id2 = _lock(alice, 1e18, MAXTIME);
        vm.prank(alice);
        vm.expectRevert(bytes("DW"));
        votingEscrow.merge(id2, id);

        // outside the window it works
        vm.warp(block.timestamp + HybraTimeLibrary.NO_VOTING_WINDOW);
        vm.prank(bob);
        votingEscrow.deposit_for(id, 1e18);
    }

    /// End-to-end: gHYBR's veNFT is voted by the operator (its normal operating mode). During the no-voting
    /// window of every epoch, gHYBR.deposit and gHYBR.receivePenaltyReward revert, so rHYBR redeem to HYBR
    /// and to gHYBR both revert.
    function test_gHybrDepositAndRHybrRedeemBlockedInWindow() public {
        // bootstrap gHYBR with a first deposit (creates its veNFT)
        hybr.approve(address(gHybr), type(uint256).max);
        gHybr.deposit(1000e18, address(this));
        uint256 gId = gHybr.veTokenId();
        assertGt(gId, 0);

        // operator votes with gHYBR's veNFT
        gHybr.setVoter(address(voter));
        _toVoteWindow();
        address[] memory pools = new address[](1);
        pools[0] = pool;
        uint256[] memory w = new uint256[](1);
        w[0] = 1;
        gHybr.vote(pools, w);
        assertTrue(votingEscrow.voted(gId));

        // next epoch, first NO_VOTING_WINDOW seconds
        vm.warp(HybraTimeLibrary.epochNext(block.timestamp) + 10);

        // plain gHYBR deposit reverts
        vm.expectRevert(bytes("DW"));
        gHybr.deposit(1e18, address(this));

        // rHYBR holder redeeming (both penalty route and gHYBR route) reverts
        deal(address(rewardHybr), alice, 100e18, true);
        deal(address(hybr), address(rewardHybr), 1000e18);
        vm.startPrank(alice);
        vm.expectRevert(bytes("DW"));
        rewardHybr.redeem(10e18, 0); // TO_HYBR (penalty sent to gHYBR)
        vm.expectRevert(bytes("DW"));
        rewardHybr.redeem(10e18, 2); // TO_GHYBR
        vm.stopPrank();
    }
}
