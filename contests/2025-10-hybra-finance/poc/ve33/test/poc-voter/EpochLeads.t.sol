// SPDX-License-Identifier: MIT
pragma solidity 0.8.13;

import "./VoterBase.t.sol";

contract EpochLeadsTest is VoterBase {
    /// Lead F3: emissions notified while totalWeight == 0 are never indexed and stay in GaugeManager forever.
    function test_emissionsWithNoVotesAreStranded() public {
        toNextEpoch(1);
        gaugeManager.distributeAll(); // first epoch after launch, nobody has voted yet
        uint256 stuck = hybr.balanceOf(address(gaugeManager));
        emit log_named_decimal_uint("stranded in GaugeManager", stuck, 18);
        assertGt(stuck, 0);

        // later votes and distributions never pay it out
        uint256 idA = lock(alice, 1_000_000e18);
        toVoteWindow();
        voteFor(alice, idA, pairs[0]);
        toNextEpoch(1);
        uint256 gmBefore = hybr.balanceOf(address(gaugeManager));
        minter.update_period();
        uint256 notified = hybr.balanceOf(address(gaugeManager)) - gmBefore;
        gaugeManager.distributeAll();
        uint256 toGauge = hybr.balanceOf(gauges_[0]);
        emit log_named_decimal_uint("epoch2 notified", notified, 18);
        emit log_named_decimal_uint("epoch2 to gauge0", toGauge, 18);
        emit log_named_decimal_uint("GM balance after", hybr.balanceOf(address(gaugeManager)), 18);
        emit log_named_uint("totalWeight", voter.totalWeight());
        emit log_named_uint("weights[pair0]", voter.weights(pairs[0]));
        assertGe(hybr.balanceOf(address(gaugeManager)), stuck, "original amount never recovered");
    }

    /// Lead F2: GaugeV2.emergencyWithdraw changes _totalSupply without updateReward. Check whether this
    /// creates insolvency (claims > balance) or only redistributes the withdrawer's un-checkpointed rewards.
    function test_emergencyWithdrawOnlyRedistributesNoInsolvency() public {
        uint256 idA = lock(alice, 1_000_000e18);
        toVoteWindow();
        voteFor(alice, idA, pairs[0]);
        GaugeV2 g = GaugeV2(gauges_[0]);

        uint256 la = lp(alice, 0, 1000e18);
        uint256 lb = lp(bob, 0, 1000e18);
        vm.startPrank(alice); ERC20(pairs[0]).approve(address(g), la); g.deposit(la); vm.stopPrank();
        vm.startPrank(bob); ERC20(pairs[0]).approve(address(g), lb); g.deposit(lb); vm.stopPrank();

        toNextEpoch(1);
        gaugeManager.distributeAll();
        uint256 funded = hybr.balanceOf(address(g));
        vm.warp(block.timestamp + WEEK / 2);

        address[] memory gs = new address[](1);
        gs[0] = address(g);
        gaugeFactory.activateEmergencyMode(gs); // deployer is emergencyCouncil
        vm.prank(alice);
        g.emergencyWithdraw();
        vm.warp(block.timestamp + WEEK);

        uint256 claims = g.earned(alice) + g.earned(bob);
        emit log_named_decimal_uint("funded", funded, 18);
        emit log_named_decimal_uint("alice earned", g.earned(alice), 18);
        emit log_named_decimal_uint("bob earned", g.earned(bob), 18);
        assertLe(claims, funded, "no insolvency");
        assertApproxEqRel(g.earned(bob), funded, 1e14, "bob takes alice's un-checkpointed half");
    }

    /// Lead F20: vote weight is fixed at vote time and never decays; only owner/VE may poke.
    /// A lock that has decayed to ~0 keeps full weight (and bribe share) indefinitely.
    function test_staleVoteWeightNeverDecays() public {
        vm.startPrank(alice);
        hybr.approve(address(votingEscrow), 1_000_000e18);
        uint256 idA = votingEscrow.create_lock(1_000_000e18, 2 * WEEK * 20); // short lock
        vm.stopPrank();
        uint256 idB = lock(bob, 1_000_000e18);
        toVoteWindow();
        voteFor(alice, idA, pairs[0]);
        voteFor(bob, idB, pairs[1]);
        uint256 wAliceAtVote = voter.weights(pairs[0]);

        vm.warp(block.timestamp + 2 * WEEK * 20 + 1); // alice's lock fully expired
        assertEq(votingEscrow.balanceOfNFT(idA), 0);
        assertEq(voter.weights(pairs[0]), wAliceAtVote, "weight unchanged after expiry");

        // bob can't correct it
        vm.prank(bob);
        vm.expectRevert(bytes("NAO||VE"));
        voter.poke(idA);

        // alice's expired lock still directs emissions
        toNextEpoch(1);
        gaugeManager.distributeAll();
        assertGt(hybr.balanceOf(gauges_[0]), 0);
    }

    /// Killed gauge: its share goes back to the minter (not lost); revive resumes normally.
    function test_killedGaugeShareReturnedToMinter() public {
        uint256 idA = lock(alice, 1_000_000e18);
        uint256 idB = lock(bob, 1_000_000e18);
        toVoteWindow();
        voteFor(alice, idA, pairs[0]);
        voteFor(bob, idB, pairs[1]);
        gaugeManager.killGauge(gauges_[1]);

        toNextEpoch(1);
        gaugeManager.distributeAll();
        assertEq(hybr.balanceOf(gauges_[1]), 0);
        uint256 minterBal = hybr.balanceOf(address(minter));
        assertApproxEqRel(minterBal, hybr.balanceOf(gauges_[0]), 1e15, "killed half returned to minter");
        assertLe(hybr.balanceOf(address(gaugeManager)), 1e9, "nothing stranded (dust only)");

        gaugeManager.reviveGauge(gauges_[1]);
        toNextEpoch(1);
        gaugeManager.distributeAll();
        assertGt(hybr.balanceOf(gauges_[1]), 0);
        assertLe(hybr.balanceOf(address(gaugeManager)), 1e9);
    }

    /// Skipped epochs: a late update_period mints only one epoch's emission (V12-known), but check that
    /// distributions still reach all gauges and nothing is stranded.
    function test_lateDistributionStillConsistent() public {
        uint256 idA = lock(alice, 1_000_000e18);
        uint256 idB = lock(bob, 1_000_000e18);
        toVoteWindow();
        voteFor(alice, idA, pairs[0]);
        voteFor(bob, idB, pairs[1]);
        vm.warp(block.timestamp + 5 * WEEK);
        gaugeManager.distributeAll();
        assertApproxEqRel(hybr.balanceOf(gauges_[0]), hybr.balanceOf(gauges_[1]), 1e15);
        assertLe(hybr.balanceOf(address(gaugeManager)), 1e9);
        assertEq(minter.epochCount(), 1, "one mint for 5 skipped epochs (V12-known)");
    }
}
