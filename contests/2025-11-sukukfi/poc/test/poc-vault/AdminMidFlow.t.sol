// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "./VaultBase.sol";
import {ERC20Faucet6} from "../../src/ERC20Faucet6.sol";

contract AdminMidFlowTest is VaultBase {
    /// setInvestmentVault only checks asset match; a vault with a different share token makes the already-invested
    /// position (held in the old investment share token) keep counting, but new investments go uncounted.
    function test_setInvestmentVaultToOtherShareTokenHidesNewInvestments() public {
        depositFlow(alice, 20_000e18);
        vm.startPrank(owner);
        WERC7575ShareToken otherShare = new WERC7575ShareToken("Other", "OTH");
        WERC7575Vault otherVault = new WERC7575Vault(address(asset), otherShare);
        otherShare.registerVault(address(asset), address(otherVault));
        otherShare.setKycAdmin(owner);
        otherShare.setKycVerified(address(shareToken), true);
        vault.setInvestmentVault(otherVault);
        vm.stopPrank();

        (, uint256 navBefore) = shareToken.getCirculatingSupplyAndAssets();
        vm.prank(investmentManager);
        vault.investAssets(10_000e18);
        (, uint256 navAfter) = shareToken.getCirculatingSupplyAndAssets();
        assertEq(navBefore - navAfter, 10_000e18, "10k silently disappears from NAV");
    }

    /// withdrawFromInvestment(type(uint256).max) — the "withdraw everything" idiom used in the repo's own tests —
    /// overflows in previewWithdraw when the asset has < 18 decimals (scaling factor > 1).
    function test_withdrawAllOverflowsFor6DecimalAsset() public {
        vm.startPrank(owner);
        ERC20Faucet6 usdc = new ERC20Faucet6("USDC", "USDC", 0);
        WERC7575ShareToken iShare = new WERC7575ShareToken("iUSDC", "iUSDC");
        WERC7575Vault iVault = new WERC7575Vault(address(usdc), iShare);
        iShare.registerVault(address(usdc), address(iVault));
        iShare.setValidator(validator);
        iShare.setKycAdmin(validator);
        ShareTokenUpgradeable st = ShareTokenUpgradeable(address(new ERC1967Proxy(address(new ShareTokenUpgradeable()),
            abi.encodeWithSelector(ShareTokenUpgradeable.initialize.selector, "S6", "S6", owner))));
        ERC7575VaultUpgradeable v = ERC7575VaultUpgradeable(address(new ERC1967Proxy(address(new ERC7575VaultUpgradeable()),
            abi.encodeWithSelector(ERC7575VaultUpgradeable.initialize.selector, IERC20(address(usdc)), address(st), owner))));
        st.registerVault(address(usdc), address(v));
        st.setInvestmentManager(investmentManager);
        st.setInvestmentShareToken(address(iShare));
        vm.stopPrank();
        vm.prank(validator);
        iShare.setKycVerified(address(st), true);

        deal(address(usdc), alice, 10_000e6);
        vm.startPrank(alice);
        usdc.approve(address(v), type(uint256).max);
        v.requestDeposit(10_000e6, alice, alice);
        vm.stopPrank();
        vm.prank(investmentManager);
        v.fulfillDeposit(alice, 10_000e6);
        vm.prank(investmentManager);
        v.investAssets(5_000e6);

        vm.prank(investmentManager);
        vm.expectRevert(); // arithmetic overflow in previewWithdraw (mulDiv(max, 1e12))
        v.withdrawFromInvestment(type(uint256).max);
    }
}
