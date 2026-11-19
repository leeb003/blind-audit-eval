// SPDX-License-Identifier: MIT
pragma solidity 0.8.13;

import "./VeBase.t.sol";

/// Lead: _checkpoint always appends a new user point (and a new global point) even when one already exists
/// for block.timestamp. balanceOfNFT / totalSupplyAtT binary-search by ts and return the FIRST match found,
/// so after 2+ same-timestamp updates they can return a stale (earlier) point.
contract SameBlockPointsTest is VeBase {
    function setUp() public override {
        super.setUp();
        _setupGauge();
    }

    function test_balanceStaleAfterTwoUpdatesSameBlock() public {
        uint256 id = _lock(alice, 1000e18, MAXTIME);
        vm.warp(block.timestamp + 1 hours);
        vm.roll(block.number + 1);

        vm.startPrank(alice);
        votingEscrow.increase_amount(id, 1000e18);
        votingEscrow.increase_amount(id, 1000e18);
        vm.stopPrank();

        uint256 bal = votingEscrow.balanceOfNFT(id);
        uint256 expected = votingEscrow.balanceOfNFTAt(id, block.timestamp + 1) + 1; // ~ true value 1s later
        emit log_named_decimal_uint("balanceOfNFT now", bal, 18);
        emit log_named_decimal_uint("true (t+1)      ", expected, 18);
        assertLt(bal, expected * 9 / 10, "reports stale balance (missing the latest increase)");
    }

    /// gHYBR-style flow: vote weight recorded by poke inside a same-block second update is understated.
    function test_pokeUsesStaleWeightSameBlock() public {
        uint256 id = _lock(alice, 1000e18, MAXTIME);
        _toVoteWindow();
        _vote(alice, id);
        vm.warp(block.timestamp + 60);
        vm.roll(block.number + 1);

        vm.startPrank(alice);
        votingEscrow.increase_amount(id, 1000e18); // poke #1
        votingEscrow.increase_amount(id, 1000e18); // poke #2 reads balanceOfNFT
        vm.stopPrank();

        uint256 recorded = voter.votes(id, pool);
        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 1);
        uint256 truth = votingEscrow.balanceOfNFT(id);
        emit log_named_decimal_uint("vote weight recorded", recorded, 18);
        emit log_named_decimal_uint("actual balance      ", truth, 18);
        assertLt(recorded, truth * 9 / 10);
    }
}
