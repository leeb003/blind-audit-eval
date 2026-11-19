// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "./CrossBase.t.sol";

/// Lead: unregisterVault requires activeDepositRequestersCount == 0 (and redeem equivalents). A controller is only
/// removed from activeDepositRequesters when it claims ALL of its claimable deposit. Nobody but the controller (or
/// its operator) can claim, so any user who leaves a fulfilled deposit unclaimed blocks unregisterVault forever.
contract UnregisterDoSTest is CrossBase {
    function test_unclaimedDepositBlocksUnregisterForever() public {
        (DecMock a, ERC7575VaultUpgradeable v,) = addAsset(6);
        // griefer requests the minimum deposit (1000 tokens) and never claims after fulfilment
        address griefer = makeAddr("griefer");
        a.mint(griefer, 1000e6);
        vm.startPrank(griefer);
        a.approve(address(v), 1000e6);
        v.requestDeposit(1000e6, griefer, griefer);
        vm.stopPrank();
        vm.prank(im);
        v.fulfillDeposit(griefer, 1000e6);

        // owner deactivates the vault to retire it
        vm.prank(owner);
        v.setVaultActive(false);

        // IM cannot claim on the griefer's behalf (only controller/operator)
        vm.prank(im);
        vm.expectRevert();
        v.deposit(1000e6, griefer, griefer);

        // owner cannot unregister
        vm.prank(owner);
        vm.expectRevert();
        shareToken.unregisterVault(address(a));

        // cancel path does not help either: cancel only works for PENDING deposits
        vm.prank(griefer);
        vm.expectRevert();
        v.cancelDepositRequest(0, griefer);

        // and the griefer loses nothing: can still claim shares any time
        vm.prank(griefer);
        uint256 s = v.deposit(1000e6, griefer);
        assertGt(s, 0);
    }

    /// Cheaper variant: dust left behind by a partial claim also keeps the controller "active".
    function test_partialClaimKeepsControllerActive() public {
        (DecMock a, ERC7575VaultUpgradeable v,) = addAsset(6);
        address griefer = makeAddr("griefer");
        a.mint(griefer, 1000e6);
        vm.startPrank(griefer);
        a.approve(address(v), 1000e6);
        v.requestDeposit(1000e6, griefer, griefer);
        vm.stopPrank();
        vm.prank(im);
        v.fulfillDeposit(griefer, 1000e6);
        vm.prank(griefer);
        v.deposit(1000e6 - 1, griefer); // claims everything but 1 wei of asset
        (uint256 dep,) = v.getActiveRequestersCount();
        assertEq(dep, 1);
        vm.prank(owner);
        v.setVaultActive(false);
        vm.prank(owner);
        vm.expectRevert();
        shareToken.unregisterVault(address(a));
    }

    /// Cheapest variant (same idea the settle reviewer found on WERC7575ShareToken): unregisterVault also requires
    /// asset.balanceOf(vault) == 0 (ShareTokenUpgradeable.sol:318) and the vault has no sweep -> 1 wei donation blocks it.
    function test_oneWeiDonationBlocksUnregister() public {
        (DecMock a, ERC7575VaultUpgradeable v,) = addAsset(6);
        vm.prank(owner);
        v.setVaultActive(false);
        a.mint(address(this), 1);
        a.transfer(address(v), 1);
        vm.prank(owner);
        vm.expectRevert(bytes4(keccak256("CannotUnregisterVaultAssetBalance()")));
        shareToken.unregisterVault(address(a));
    }
}
