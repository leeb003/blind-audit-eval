// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "./VaultBase.sol";

/// Lead S: totalAssets() floors at 0 when reserved (claimable redeem) assets exceed the vault's idle balance.
/// Once assets are invested, fulfilling redemptions reserves assets that sit in the investment vault; the
/// deficit is never subtracted, so the shared NAV counts the redeemed assets twice (reserved AND invested)
/// while the redeemed shares are excluded from circulating supply -> share price inflates.
contract ReservedFloorTest is VaultBase {
    function test_fulfillRedeemAfterInvestInflatesSharePrice() public {
        uint256 aShares = depositFlow(alice, 10_000e18);
        uint256 bShares = depositFlow(bob, 10_000e18);
        assertEq(vault.convertToAssets(1e18), 1e18 - 0, "price 1:1 before");

        // manager invests everything idle (allowed: amount <= totalAssets())
        vm.prank(investmentManager);
        vault.investAssets(20_000e18);

        // alice redeems; manager fulfils (standard flow; manager will divest later to fund the claim)
        requestRedeem(alice, aShares);
        uint256 reserved = fulfillRedeem(alice, aShares);
        assertEq(reserved, 10_000e18);

        // vault holds 0 idle, reserved 10k -> totalAssets() = 0 instead of -10k
        assertEq(vault.totalAssets(), 0);
        (uint256 circ, uint256 nav) = shareToken.getCirculatingSupplyAndAssets();
        assertEq(circ, bShares);          // only bob's 10k shares circulate
        assertEq(nav, 20_000e18);         // but NAV still counts all 20k invested
        uint256 bobValue = vault.convertToAssets(bShares);
        emit log_named_decimal_uint("bob's 10k shares now worth", bobValue, 18);
        assertApproxEqRel(bobValue, 20_000e18, 1e12, "bob's shares doubled in value");

        // bob redeems at the inflated price -> total claims 30k against 20k of real assets
        requestRedeem(bob, bShares);
        uint256 bobAssets = fulfillRedeem(bob, bShares);
        assertApproxEqRel(bobAssets, 20_000e18, 1e12);

        // manager divests everything; alice claims first, bob can't be paid in full
        vm.prank(investmentManager);
        vault.withdrawFromInvestment(20_000e18);
        vm.prank(alice);
        vault.redeem(aShares, alice, alice);
        vm.prank(bob);
        vm.expectRevert();
        vault.redeem(bShares, bob, bob);
    }

    /// Same root cause hits NEW depositors: while the deficit exists, fulfilled deposits get half the shares.
    function test_newDepositorsDilutedDuringWindow() public {
        uint256 aShares = depositFlow(alice, 10_000e18);
        depositFlow(bob, 10_000e18);
        vm.prank(investmentManager);
        vault.investAssets(20_000e18);
        requestRedeem(alice, aShares);
        fulfillRedeem(alice, aShares);

        uint256 cShares = depositFlow(carol, 10_000e18);
        emit log_named_decimal_uint("carol shares for 10k assets", cShares, 18);
        assertApproxEqRel(cShares, 5_000e18, 1e12, "carol receives ~half the fair shares");
    }
}
