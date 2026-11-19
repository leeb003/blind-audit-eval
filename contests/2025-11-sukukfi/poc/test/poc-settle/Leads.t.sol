// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "./SettleBase.t.sol";
import {WERC7575Vault} from "../../src/WERC7575Vault.sol";

contract LeadsTest is SettleBase {
    // ---------- L2: unregisterVault blocked forever by a 1-wei donation ----------
    function test_L2_dustDonationBlocksUnregisterVault() public {
        uint256 shares = depositFor(alice, 1_000e6);
        grantSelfAllowance(alice, type(uint256).max);
        vm.prank(alice);
        vault.redeem(shares, alice, alice); // vault fully emptied by users
        assertEq(usdc.balanceOf(address(vault)), 0);

        // griefer donates 1 unit of USDC directly to the vault
        vm.prank(bob);
        usdc.transfer(address(vault), 1);

        // owner can no longer unregister; there is no sweep/skim function to remove the dust
        vm.expectRevert();
        shareToken.unregisterVault(address(usdc));

        // and since only one vault per asset is allowed, a replacement vault can't be registered
        WERC7575Vault v2 = new WERC7575Vault(address(usdc), shareToken);
        vm.expectRevert();
        shareToken.registerVault(address(usdc), address(v2));
    }

    // ---------- L3: adjustrBalance / batchTransfers / permit ignore ShareToken pause ----------
    // pause() natspec: "Used for emergency situations to halt batch transfers and rBalance adjustments."
    function test_L3_pauseDoesNotHaltBatchOrAdjustments() public {
        depositFor(alice, 1_000e6);
        shareToken.pause();

        address[] memory d = new address[](1);
        address[] memory c = new address[](1);
        uint256[] memory a = new uint256[](1);
        d[0] = alice; c[0] = bob; a[0] = 100e18;
        vm.prank(validator);
        shareToken.batchTransfers(d, c, a); // not halted
        assertEq(shareToken.balanceOf(bob), 100e18);

        vm.warp(1000);
        vm.prank(validator);
        shareToken.adjustrBalance(alice, 1, 10e18, 20e18); // not halted
        assertEq(shareToken.rBalanceOf(alice), 10e18);
    }

    // ---------- L4: transferFrom with caller == from spends self-allowance twice ----------
    function test_L4_transferFromSelfDoubleSpendsSelfAllowance() public {
        depositFor(alice, 1_000e6);
        grantSelfAllowance(alice, 100e18);
        vm.prank(alice);
        vm.expectRevert(); // 60 + 60 > 100 even though only 60 moves
        shareToken.transferFrom(alice, bob, 60e18);
        vm.prank(alice);
        shareToken.transferFrom(alice, bob, 50e18);
        assertEq(shareToken.allowance(alice, alice), 0, "100 of self-allowance used for a 50 transfer");
    }

    // ---------- Disproof: permit replay / cross-chain ----------
    function test_D_permitReplayRejected() public {
        uint256 deadline = block.timestamp + 1 days;
        bytes32 digest = _permitDigest(alice, alice, 1e18, shareToken.nonces(alice), deadline);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(validatorPk, digest);
        shareToken.permit(alice, alice, 1e18, deadline, v, r, s);
        vm.expectRevert();
        shareToken.permit(alice, alice, 1e18, deadline, v, r, s);
    }

    function test_D_permitOtherChainRejected() public {
        uint256 deadline = block.timestamp + 1 days;
        bytes32 digest = _permitDigest(alice, alice, 1e18, shareToken.nonces(alice), deadline);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(validatorPk, digest);
        vm.chainId(999);
        vm.expectRevert();
        shareToken.permit(alice, alice, 1e18, deadline, v, r, s);
    }

    /// user cannot self-authorize: own signature for owner==spender is rejected; approve(self) blocked
    function test_D_userCannotSelfAuthorize() public {
        uint256 deadline = block.timestamp + 1 days;
        bytes32 digest = _permitDigest(alice, alice, 1e18, shareToken.nonces(alice), deadline);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(alicePk, digest);
        vm.expectRevert();
        shareToken.permit(alice, alice, 1e18, deadline, v, r, s);
        vm.prank(alice);
        vm.expectRevert();
        shareToken.approve(alice, 1e18);
    }

    /// old validator's signatures die on validator rotation (mid-flow setter)
    function test_D_validatorRotationInvalidatesOldSigs() public {
        uint256 deadline = block.timestamp + 1 days;
        bytes32 digest = _permitDigest(alice, alice, 1e18, shareToken.nonces(alice), deadline);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(validatorPk, digest);
        shareToken.setValidator(makeAddr("newValidator"));
        vm.expectRevert();
        shareToken.permit(alice, alice, 1e18, deadline, v, r, s);
    }

    // ---------- Disproof: KYC on mint ----------
    function test_D_mintRequiresKyc() public {
        vm.startPrank(bob);
        usdc.approve(address(vault), 1e6);
        vm.expectRevert();
        vault.deposit(1e6, attacker);
        vm.stopPrank();
    }

    // ---------- Disproof: rounding on 6-dec asset never favours the user ----------
    function testFuzz_D_roundingNeverFavoursUser(uint256 assets, uint256 dust) public {
        assets = bound(assets, 1, 100_000e6);
        uint256 shares = depositFor(alice, assets);
        assertEq(shares, assets * 1e12);
        grantSelfAllowance(alice, type(uint256).max);
        // redeem a non-multiple of scaling factor: assets rounded down
        dust = bound(dust, 1, 1e12 - 1);
        if (shares > dust) {
            uint256 before = usdc.balanceOf(alice);
            vm.prank(alice);
            try vault.redeem(shares - dust, alice, alice) returns (uint256 out) {
                assertLe(out * 1e12, shares - dust);
                assertEq(usdc.balanceOf(alice) - before, out);
            } catch {}
        }
        // mint rounding up
        vm.startPrank(bob);
        usdc.approve(address(vault), type(uint256).max);
        uint256 paid = vault.mint(1, bob);
        vm.stopPrank();
        assertEq(paid, 1, "1 wei share costs 1 asset unit (ceil)");
        assertGe(usdc.balanceOf(address(vault)) * 1e12, shareToken.totalSupply());
    }
}
