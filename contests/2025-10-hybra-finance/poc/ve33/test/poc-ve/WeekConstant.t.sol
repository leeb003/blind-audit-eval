// SPDX-License-Identifier: MIT
pragma solidity 0.8.13;

import "./VeBase.t.sol";

/// Lead: HybraTimeLibrary.WEEK = 1800 (30 min; the 7-day value is commented out). VotingEscrow._checkpoint
/// fills global history one WEEK per iteration, capped at 255 iterations (designed for ~5 years at 7-day weeks).
/// With 30-minute weeks the cap is 255 * 1800s = ~5.3 days: any 5.3-day gap without a VE checkpoint leaves the
/// global point stale and total voting supply wrong.
contract WeekConstantTest is VeBase {
    function test_weekIs30Minutes() public {
        assertEq(HybraTimeLibrary.WEEK, 1800);
    }

    function test_checkpointCapBreaksTotalSupplyAfterIdleGap() public {
        uint256 a = _lock(alice, 1000e18, MAXTIME);
        vm.warp(block.timestamp + 1 hours);
        // sanity: supply equals sum of balances while active
        assertApproxEqAbs(votingEscrow.totalSupply(), votingEscrow.balanceOfNFT(a), 1e6);

        // 6 days with no VE interaction (> 255 * 30min)
        vm.warp(block.timestamp + 6 days);
        vm.roll(block.number + 1);
        uint256 b = _lock(bob, 1000e18, MAXTIME);

        uint256 sumBal = votingEscrow.balanceOfNFT(a) + votingEscrow.balanceOfNFT(b);
        uint256 ts = votingEscrow.totalSupply();
        emit log_named_decimal_uint("sum of balances", sumBal, 18);
        emit log_named_decimal_uint("totalSupply    ", ts, 18);
        IVotingEscrow.Point memory p = votingEscrow.point_history(votingEscrow.epoch());
        emit log_named_uint("latest global point ts lag (s)", block.timestamp - p.ts);
        assertGt(block.timestamp - p.ts, 0, "global point did not reach now");
        assertTrue(ts + 1e15 < sumBal || ts > sumBal + 1e15, "totalSupply diverges from sum of balances");
    }
}
