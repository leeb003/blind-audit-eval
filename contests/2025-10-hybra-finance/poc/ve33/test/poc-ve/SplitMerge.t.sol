// SPDX-License-Identifier: MIT
pragma solidity 0.8.13;

import "./VeBase.t.sol";
interface IBribeY { function notifyRewardAmount(address, uint256) external; }
interface IBribeX {
    function earned(uint256, address) external view returns (uint256);
    function getPriorBalanceIndex(uint256, uint256) external view returns (uint256);
}

/// Leads around merge / multiSplit / permanent locks. Includes the tests used to dismiss leads.
contract SplitMergeTest is VeBase {
    function setUp() public override {
        super.setUp();
        _setupGauge();
        votingEscrow.toggleSplit(address(0), true);
    }

    function _amt(uint256 id) internal view returns (uint256) {
        (int128 a,,) = votingEscrow.locked(id);
        return uint256(int256(a));
    }

    function _sumPermanent(uint256[] memory ids) internal view returns (uint256 s) {
        for (uint256 i; i < ids.length; i++) {
            (int128 a,, bool p) = votingEscrow.locked(ids[i]);
            if (p) s += uint256(int256(a));
        }
    }

    // ---------- L: multiSplit rounding dust is stranded forever ----------
    function test_multiSplitDustStranded() public {
        uint256 id = _lock(alice, 1000e18 + 1, MAXTIME);
        uint256[] memory w = new uint256[](3);
        w[0] = 1; w[1] = 1; w[2] = 1;
        vm.prank(alice);
        uint256[] memory kids = votingEscrow.multiSplit(id, w);
        uint256 sum = _amt(kids[0]) + _amt(kids[1]) + _amt(kids[2]);
        assertEq(votingEscrow.supply() - sum, 2, "2 wei (rounding remainder) locked in VE with no owner");
        // after expiry every child withdraws, dust stays and supply never returns to 0
        vm.warp(block.timestamp + MAXTIME + 1);
        vm.startPrank(alice);
        for (uint256 i; i < 3; i++) votingEscrow.withdraw(kids[i]);
        vm.stopPrank();
        assertEq(votingEscrow.supply(), 2);
    }

    // ---------- L: merge/split burns the NFT, orphaning unclaimed bribes ----------
    function test_mergeOrphansUnclaimedBribes() public {
        uint256 a = _lock(alice, 1000e18, MAXTIME);
        uint256 a2 = _lock(alice, 1000e18, MAXTIME);
        _toVoteWindow();
        _vote(alice, a);
        // bribe paid for this epoch on the external bribe
        address ext = gaugeManager.external_bribes(gauge);
        // bribe of 100 HYBR (whitelisted token) for this epoch
        hybr.approve(ext, type(uint256).max);
        IBribeY(ext).notifyRewardAmount(address(hybr), 100e18);
        uint256 aliceBefore = hybr.balanceOf(alice);
        // next epoch: reset, then merge a into a2 before claiming
        _toVoteWindow();
        vm.startPrank(alice);
        voter.reset(a);
        uint256 owed = IBribeX(ext).earned(a, address(hybr));
        emit log_named_decimal_uint("bribe owed to merged-away NFT", owed, 18);
        assertGt(owed, 99e18);
        votingEscrow.merge(a, a2);
        address[] memory b = new address[](1); b[0] = ext;
        address[][] memory t = new address[][](1); t[0] = new address[](1); t[0][0] = address(hybr);
        vm.expectRevert(bytes("NAO"));
        gaugeManager.claimBribes(b, t, a);
        gaugeManager.claimBribes(b, t, a2); // a2 never voted -> receives nothing
        vm.stopPrank();
        assertEq(hybr.balanceOf(alice), aliceBefore);
    }

    // ---------- Dismissals ----------

    /// D1: merge normal->permanent and permanent->permanent keep permanentLockBalance and supply consistent.
    function test_dismiss_mergePermanentAccounting() public {
        uint256 p1 = _lock(alice, 500e18, MAXTIME);
        uint256 p2 = _lock(alice, 300e18, MAXTIME);
        uint256 n = _lock(alice, 200e18, MAXTIME / 2);
        vm.startPrank(alice);
        votingEscrow.lockPermanent(p1);
        votingEscrow.lockPermanent(p2);
        votingEscrow.merge(n, p1);   // normal -> permanent
        votingEscrow.merge(p2, p1);  // permanent -> permanent
        vm.stopPrank();
        assertEq(votingEscrow.permanentLockBalance(), 1000e18);
        assertEq(_amt(p1), 1000e18);
        uint256 t1 = 1 + 1; // setUp starts at ts 1; read one second later (same-second reads are stale, see SameBlockPoints)
        vm.warp(t1);
        assertEq(votingEscrow.balanceOfNFTAt(p1, t1), 1000e18);
        assertApproxEqAbs(votingEscrow.totalSupplyAtT(t1), 1000e18, 1e9);
    }

    /// D2: multiSplit (normal and permanent) cannot increase voting power or permanent balance.
    function testFuzz_dismiss_multiSplitNoInflation(uint96 amt, uint8 n, uint64 seed, bool perm) public {
        amt = uint96(bound(amt, 1e18, 1e25));
        n = uint8(bound(n, 2, 10));
        uint256 id = _lock(alice, amt, MAXTIME);
        if (perm) { vm.prank(alice); votingEscrow.lockPermanent(id); }
        vm.roll(block.number + 1);
        uint256 before = votingEscrow.balanceOfNFT(id);
        uint256 permBefore = votingEscrow.permanentLockBalance();
        uint256[] memory w = new uint256[](n);
        for (uint256 i; i < n; i++) w[i] = uint256(keccak256(abi.encode(seed, i))) % 1e6 + 1e3;
        vm.prank(alice);
        uint256[] memory kids = votingEscrow.multiSplit(id, w);
        uint256 t1 = 1 + 1; // read one second later (same-second reads are stale, see SameBlockPoints)
        vm.warp(t1);
        uint256 sum;
        for (uint256 i; i < n; i++) sum += votingEscrow.balanceOfNFTAt(kids[i], t1);
        assertLe(sum, votingEscrow.balanceOfNFTAt(id, 1) + 1);
        assertLe(_sumPermanent(kids), permBefore);
        assertApproxEqAbs(votingEscrow.totalSupplyAtT(t1), sum, 1e12);
        before;
    }

    /// D3: permanent lock lifecycle keeps permanentLockBalance == sum of permanent locks.
    function test_dismiss_permanentLifecycle() public {
        uint256 a = _lock(alice, 100e18, MAXTIME);
        uint256 b = _lock(bob, 50e18, MAXTIME);
        vm.prank(alice); votingEscrow.lockPermanent(a);
        vm.prank(bob); votingEscrow.lockPermanent(b);
        vm.prank(bob); votingEscrow.deposit_for(a, 10e18);
        vm.prank(alice); votingEscrow.increase_amount(a, 5e18);
        vm.prank(bob); votingEscrow.unlockPermanent(b);
        assertEq(votingEscrow.permanentLockBalance(), 115e18);
        uint256 t1 = 1 + 1;
        vm.warp(t1);
        assertApproxEqAbs(votingEscrow.totalSupplyAtT(t1), votingEscrow.balanceOfNFTAt(a, t1) + votingEscrow.balanceOfNFTAt(b, t1), 1e9);
    }

    /// D4: a voted NFT cannot be transferred, split, merged-from, withdrawn or unlocked (no double voting).
    function test_dismiss_votedNftFrozen() public {
        uint256 a = _lock(alice, 100e18, MAXTIME);
        uint256 a2 = _lock(alice, 100e18, MAXTIME);
        _toVoteWindow();
        _vote(alice, a);
        uint256[] memory w = new uint256[](2); w[0] = 1; w[1] = 1;
        vm.startPrank(alice);
        vm.expectRevert(bytes("ATT")); votingEscrow.transferFrom(alice, bob, a);
        vm.expectRevert(bytes("ATT")); votingEscrow.multiSplit(a, w);
        vm.expectRevert(bytes("ATT")); votingEscrow.merge(a, a2);
        vm.expectRevert(bytes("VOTED")); voter.reset(a); // same epoch
        vm.stopPrank();
    }

    /// D5 (sponsor concern #2): extending/increasing a voted lock mid-epoch does not change earnings of a
    /// previous epoch; the checkpoint used for an epoch is the last one inside it.
    function test_dismiss_extendDoesNotAlterPriorEpochBalanceCheckpoint() public {
        uint256 a = _lock(alice, 100e18, MAXTIME / 2);
        _toVoteWindow();
        _vote(alice, a);
        address ext = gaugeManager.external_bribes(gauge);
        uint256 prevEpoch = HybraTimeLibrary.epochStart(block.timestamp);
        uint256 idxBefore = IBribeX(ext).getPriorBalanceIndex(a, prevEpoch + WEEK - 1);
        _toVoteWindow();
        vm.prank(alice);
        votingEscrow.increase_unlock_time(a, MAXTIME); // pokes in new epoch
        uint256 idxAfter = IBribeX(ext).getPriorBalanceIndex(a, prevEpoch + WEEK - 1);
        assertEq(idxAfter, idxBefore, "previous epoch still resolves to the same checkpoint");
    }

    /// D6: lock bounds respected (no lock beyond MAXTIME, no extension of expired locks).
    function test_dismiss_lockBounds() public {
        vm.prank(alice);
        vm.expectRevert(bytes("IUT"));
        votingEscrow.create_lock(1e18, MAXTIME + WEEK);
        uint256 a = _lock(alice, 1e18, WEEK * 2);
        vm.warp(block.timestamp + WEEK * 3);
        vm.prank(alice);
        vm.expectRevert(bytes("EXP||ZV"));
        votingEscrow.increase_unlock_time(a, MAXTIME);
    }

    /// D7: flash-transfer protection — received NFT has 0 power in the block of transfer, so it can't vote.
    function test_dismiss_flashTransferZeroPower() public {
        uint256 a = _lock(alice, 100e18, MAXTIME);
        _toVoteWindow();
        vm.prank(alice);
        votingEscrow.transferFrom(alice, bob, a);
        assertEq(votingEscrow.balanceOfNFT(a), 0);
        address[] memory pools = new address[](1); pools[0] = pool;
        uint256[] memory w = new uint256[](1); w[0] = 1;
        vm.prank(bob);
        vm.expectRevert(bytes("ZV"));
        voter.vote(a, pools, w);
    }
}
