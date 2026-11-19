// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "./CrossBase.t.sol";

/// Lead: ERC7575VaultUpgradeable.totalAssets() clamps (balance - reserved) at 0. When redeems are fulfilled while
/// assets are invested (fulfillRedeem does not check liquidity), the vault's negative position is dropped, but the
/// invested assets are still counted by ShareToken._calculateInvestmentAssets -> global share price is inflated.
contract ReservedClampTest is CrossBase {
    function test_fulfillRedeemWhileInvested_inflatesPriceForNextRedeemer() public {
        (DecMock a, ERC7575VaultUpgradeable v,) = addAsset(18);
        uint256 sA = depositFlow(v, a, alice, 1000e18);
        uint256 sB = depositFlow(v, a, bob, 1000e18);

        // IM invests all idle assets (allowed: totalAssets() == 2000e18)
        vm.prank(im);
        v.investAssets(2000e18);

        // both users ask to exit
        requestRedeem(v, alice, sA);
        requestRedeem(v, bob, sB);

        // IM fulfills alice first: correctly priced at 1000e18
        vm.prank(im);
        uint256 aliceAssets = v.fulfillRedeem(alice, sA);
        assertApproxEqAbs(aliceAssets, 1000e18, 1e6);

        // vault now owes 1000e18 but holds 0 -> totalAssets() returns 0 instead of -1000e18
        assertEq(v.totalAssets(), 0);

        // IM fulfills bob: same share count, but priced off 2000e18 of assets for bob's shares alone
        vm.prank(im);
        uint256 bobAssets = v.fulfillRedeem(bob, sB);
        emit log_named_decimal_uint("alice claimable", aliceAssets, 18);
        emit log_named_decimal_uint("bob claimable  ", bobAssets, 18);
        assertGt(bobAssets, 1900e18, "bob is owed ~2x his deposit");

        // total owed 3000e18 but only 2000e18 exist: after IM pulls everything back, the last claimer is short
        permitShareTokenSelf();
        vm.prank(im);
        v.withdrawFromInvestment(2000e18);
        vm.prank(bob);
        v.redeem(sB, bob, bob); // bob exits first with ~2000e18
        vm.prank(alice);
        vm.expectRevert(); // alice's 1000e18 is gone
        v.redeem(sA, alice, alice);
    }
}
