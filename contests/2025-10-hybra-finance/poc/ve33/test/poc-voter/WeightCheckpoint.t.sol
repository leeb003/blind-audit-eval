// SPDX-License-Identifier: MIT
pragma solidity 0.8.13;

import "./VoterBase.t.sol";

/// Lead F1: VoterV3._vote/_reset change weights[pool]/totalWeight without first checkpointing the
/// gauge in GaugeManager (_updateForAfterDistribution). The emission index is set at notify time using
/// totalWeight then, but each gauge's share is computed later from its *live* weight.
contract WeightCheckpointTest is VoterBase {
    function _epochSetup() internal returns (uint256 idA, uint256 idB) {
        idA = lock(alice, 1_000_000e18);
        idB = lock(bob, 1_000_000e18);
        // move into voting window of current epoch
        toVoteWindow();
        voteFor(alice, idA, pairs[0]);
        voteFor(bob, idB, pairs[1]);
    }

    function test_sanity_distributeAllSplitsEvenly() public {
        _epochSetup();
        toNextEpoch(1);
        gaugeManager.distributeAll();
        uint256 a = hybr.balanceOf(gauges_[0]);
        uint256 b = hybr.balanceOf(gauges_[1]);
        assertGt(a, 0);
        assertApproxEqRel(a, b, 1e15);
    }

    /// New votes after notify but before a gauge is distributed: that gauge's share is computed from
    /// weight that was not in totalWeight at notify -> over-allocation -> distribution reverts (and with
    /// distributeAll, reverts for every gauge).
    function test_newVoteAfterNotifyOverAllocatesAndBricksDistribution() public {
        _epochSetup();
        uint256 idC = lock(carol, 1_000_000e18);

        toNextEpoch(1);
        minter.update_period(); // anyone can trigger; index += E / totalWeight(alice+bob)
        uint256 gmBal = hybr.balanceOf(address(gaugeManager));
        assertGt(gmBal, 0);

        // voting window of the new epoch opens; carol votes for pool 1 before it was distributed
        toVoteWindow();
        voteFor(carol, idC, pairs[1]);

        // gauge 0 distributes its fair half
        distributeOne(gauges_[0]);
        uint256 got0 = hybr.balanceOf(gauges_[0]);
        assertApproxEqRel(got0, gmBal / 2, 1e15);

        // gauge 1 now claims (bob+carol)/(alice+bob) = 2x its share -> more than what is left
        vm.expectRevert();
        distributeOne(gauges_[1]);

        // and the keeper's distributeAll reverts too (gauge 0 already done, gauge 1 over-allocated)
        vm.expectRevert();
        gaugeManager.distributeAll();

        // the shortfall is permanent: next epoch gauge 1 claims 2 epochs at the inflated weight,
        // so distributeAll keeps reverting and gauge 1 (bob + carol's voters/LPs) gets nothing
        for (uint256 e; e < 3; e++) {
            toNextEpoch(1);
            vm.expectRevert();
            gaugeManager.distributeAll();
            distributeOne(gauges_[0]); // gauge 0 alone still works
        }
        assertEq(hybr.balanceOf(gauges_[1]), 0, "gauge 1 never received emissions");
    }

    /// Same root cause, other direction: reset after notify but before distribution leaves the
    /// removed weight's share of emissions permanently in GaugeManager (no sweep function).
    function test_resetAfterNotifyStrandsEmissions() public {
        (, uint256 idB) = _epochSetup();

        toNextEpoch(1);
        minter.update_period();
        uint256 gmBal = hybr.balanceOf(address(gaugeManager));

        toVoteWindow();
        vm.prank(bob);
        voter.reset(idB);

        gaugeManager.distributeAll();
        uint256 stuck = hybr.balanceOf(address(gaugeManager));
        emit log_named_decimal_uint("emissions for epoch", gmBal, 18);
        emit log_named_decimal_uint("left stranded in GaugeManager", stuck, 18);
        assertApproxEqRel(stuck, gmBal / 2, 1e15, "bob's gauge share is stranded");

        // next epochs don't recover it: gauge 1 has 0 weight, index share accrues to nobody
        toNextEpoch(1);
        gaugeManager.distributeAll();
        assertGe(hybr.balanceOf(address(gaugeManager)), stuck);
    }
}
