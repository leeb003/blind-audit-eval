// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "./SettleBase.t.sol";

/// Disproof: batchTransfers / rBatchTransfers netting vs a naive per-account reference.
/// Checks final balances, zero-sum, totalSupply, and rBalance flag positions vs computeRBalanceFlags.
contract BatchFuzzTest is SettleBase {
    address[6] pool;

    function setUp() public override {
        super.setUp();
        for (uint256 i; i < 6; i++) {
            pool[i] = makeAddr(string(abi.encodePacked("acct", i)));
            vm.prank(validator);
            shareToken.setKycVerified(pool[i], true);
            vm.startPrank(bob);
            usdc.approve(address(vault), 1_000e6);
            vault.deposit(1_000e6, pool[i]);
            vm.stopPrank();
        }
    }

    function testFuzz_D_batchNettingMatchesReference(uint256 seed, uint8 n) public {
        n = uint8(bound(n, 1, 100));
        address[] memory d = new address[](n);
        address[] memory c = new address[](n);
        uint256[] memory a = new uint256[](n);
        int256[6] memory delta;
        for (uint256 i; i < n; i++) {
            uint256 r = uint256(keccak256(abi.encode(seed, i)));
            uint256 di = r % 6;
            uint256 ci = (r >> 8) % 6; // self-transfers included
            d[i] = pool[di];
            c[i] = pool[ci];
            a[i] = ((r >> 16) % 500) * 1e18;
            if (di != ci) {
                delta[di] -= int256(a[i]);
                delta[ci] += int256(a[i]);
            }
        }
        uint256[6] memory before;
        bool ok = true;
        for (uint256 k; k < 6; k++) {
            before[k] = shareToken.balanceOf(pool[k]);
            if (int256(before[k]) + delta[k] < 0) ok = false;
        }
        uint256 supply = shareToken.totalSupply();
        vm.prank(validator);
        if (!ok) {
            vm.expectRevert();
            shareToken.batchTransfers(d, c, a);
            return;
        }
        shareToken.batchTransfers(d, c, a);
        for (uint256 k; k < 6; k++) {
            assertEq(int256(shareToken.balanceOf(pool[k])), int256(before[k]) + delta[k]);
        }
        assertEq(shareToken.totalSupply(), supply);
    }

    /// rBatchTransfers with flags from computeRBalanceFlags only touches flagged accounts (no self-transfers,
    /// self-transfer misalignment is V12-known).
    function testFuzz_D_rBatchFlagsApplyToIntendedAccounts(uint256 seed, uint8 n) public {
        n = uint8(bound(n, 1, 40));
        address[] memory d = new address[](n);
        address[] memory c = new address[](n);
        uint256[] memory a = new uint256[](n);
        bool[] memory df = new bool[](n);
        bool[] memory cf = new bool[](n);
        bool[6] memory marked; // per-account consistent marking
        for (uint256 k; k < 6; k++) marked[k] = uint256(keccak256(abi.encode(seed, "m", k))) % 2 == 0;
        for (uint256 i; i < n; i++) {
            uint256 r = uint256(keccak256(abi.encode(seed, i)));
            uint256 di = r % 6;
            uint256 ci = (di + 1 + (r >> 8) % 5) % 6; // never self
            d[i] = pool[di]; c[i] = pool[ci];
            a[i] = ((r >> 16) % 100) * 1e18;
            df[i] = marked[di]; cf[i] = marked[ci];
        }
        uint256 flags = shareToken.computeRBalanceFlags(d, c, df, cf);
        uint256[6] memory rb;
        for (uint256 k; k < 6; k++) rb[k] = shareToken.rBalanceOf(pool[k]);
        vm.prank(validator);
        try shareToken.rBatchTransfers(d, c, a, flags) {
            for (uint256 k; k < 6; k++) {
                if (!marked[k]) assertEq(shareToken.rBalanceOf(pool[k]), rb[k], "unmarked account rBalance touched");
            }
        } catch {}
    }
}
