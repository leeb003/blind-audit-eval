// SPDX-License-Identifier: MIT
pragma solidity 0.8.13;
import "./CrossBase.t.sol";

/// Skeptic check of poc-ve D1 (its dismissal test fails): trace permanentLockBalance through lock/merge.
contract MergePermanentTest is CrossBase {
    function _lock(uint256 amt, uint256 dur) internal returns (uint256) {
        vm.prank(alice);
        return votingEscrow.create_lock(amt, dur);
    }
    function test_tracePermanentLockBalance() public {
        vm.warp(1_700_000_000);
        vm.prank(alice);
        hybr.approve(address(votingEscrow), type(uint256).max);
        uint256 p1 = _lock(500e18, 730 days);
        uint256 p2 = _lock(300e18, 730 days);
        uint256 n = _lock(200e18, 365 days);
        vm.startPrank(alice);
        votingEscrow.lockPermanent(p1);
        emit log_named_decimal_uint("after lockPermanent(p1)", votingEscrow.permanentLockBalance(), 18);
        votingEscrow.lockPermanent(p2);
        emit log_named_decimal_uint("after lockPermanent(p2)", votingEscrow.permanentLockBalance(), 18);
        votingEscrow.merge(n, p1);
        emit log_named_decimal_uint("after merge(n,p1)", votingEscrow.permanentLockBalance(), 18);
        votingEscrow.merge(p2, p1);
        emit log_named_decimal_uint("after merge(p2,p1)", votingEscrow.permanentLockBalance(), 18);
        vm.stopPrank();
        (int128 a,,) = votingEscrow.locked(p1);
        emit log_named_decimal_uint("locked(p1)", uint256(int256(a)), 18);
    }
}
