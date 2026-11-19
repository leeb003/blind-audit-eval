// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "./VaultBase.sol";
import {ERC7575VaultUpgradeable} from "../../src/ERC7575VaultUpgradeable.sol";
import {ERC20Faucet6} from "../../src/ERC20Faucet6.sol";

contract LeadsTest is VaultBase {
    // ---------- Lead: fulfilled redeem with 0 claimable assets leaves phantom totalClaimableRedeemShares ----------
    // Uses a 6-decimal asset so that sub-1e12 share amounts convert to 0 assets.
    function test_zeroAssetRedeemLeavesPhantomClaimableShares() public {
        vm.startPrank(owner);
        ERC20Faucet6 usdc = new ERC20Faucet6("USDC", "USDC", 0);
        ShareTokenUpgradeable st = ShareTokenUpgradeable(address(new ERC1967Proxy(address(new ShareTokenUpgradeable()),
            abi.encodeWithSelector(ShareTokenUpgradeable.initialize.selector, "S6", "S6", owner))));
        ERC7575VaultUpgradeable v = ERC7575VaultUpgradeable(address(new ERC1967Proxy(address(new ERC7575VaultUpgradeable()),
            abi.encodeWithSelector(ERC7575VaultUpgradeable.initialize.selector, IERC20(address(usdc)), address(st), owner))));
        st.registerVault(address(usdc), address(v));
        vm.stopPrank();
        deal(address(usdc), alice, 10_000e6);
        vm.startPrank(alice);
        usdc.approve(address(v), type(uint256).max);
        v.requestDeposit(10_000e6, alice, alice);
        vm.stopPrank();
        vm.prank(owner); // owner is investment manager by default
        v.fulfillDeposit(alice, 10_000e6);
        vm.startPrank(alice);
        v.deposit(10_000e6, alice);
        v.requestRedeem(3e11, alice, alice); // 0.3 micro-USDC worth -> 0 assets
        vm.stopPrank();
        vm.prank(owner);
        assertEq(v.fulfillRedeem(alice, 3e11), 0);
        // redeem 1 share: assets 0 == availableAssets 0 -> entry deleted, only 1 share burned
        vm.prank(alice);
        v.redeem(1, alice, alice);
        assertEq(v.maxRedeem(alice), 0);
        (uint256 claimable,) = v.getClaimableSharesAndNormalizedAssets();
        assertEq(claimable, 3e11 - 1, "phantom claimable shares remain forever");
        assertEq(st.balanceOf(address(v)), 3e11 - 1, "orphan shares stuck in vault");
    }

    // ---------- Dismiss: donation / inflation attack (min deposit + virtual offset) ----------
    function test_dismiss_donationDoesNotStealFromNextDepositor() public {
        uint256 aShares = depositFlow(alice, 1_000e18); // minimum deposit is 1000 tokens
        // alice redeems all but 1 wei of shares
        requestRedeem(alice, aShares - 1);
        fulfillRedeem(alice, aShares - 1);
        vm.prank(alice);
        vault.redeem(aShares - 1, alice, alice);
        // alice donates 100k directly
        vm.prank(alice);
        asset.transfer(address(vault), 100_000e18);
        uint256 bShares = depositFlow(bob, 1_000e18);
        // bob's shares are still worth ~ his deposit? value = convertToAssets(bShares)
        uint256 bobValue = vault.convertToAssets(bShares);
        // donation is captured by alice's 1 wei share + virtual shares; bob gets shares at the inflated price
        // but his claim value equals his deposit (no rounding theft beyond dust)
        assertApproxEqRel(bobValue, 1_000e18, 1e15, "bob keeps value");
        // alice's 1 wei share cannot recover the donation
        assertLt(vault.convertToAssets(1), 100_000e18 / 2, "attacker loses donation");
    }

    // ---------- Dismiss: batch fulfill vs single fulfill give same shares ----------
    function test_dismiss_batchFulfillMatchesSingle() public {
        depositFlow(carol, 50_000e18);
        vm.prank(alice); asset.approve(address(vault), type(uint256).max);
        vm.prank(bob); asset.approve(address(vault), type(uint256).max);
        vm.prank(alice); vault.requestDeposit(10_000e18, alice, alice);
        vm.prank(bob); vault.requestDeposit(10_000e18, bob, bob);
        address[] memory c = new address[](2); c[0] = alice; c[1] = bob;
        uint256[] memory a = new uint256[](2); a[0] = 10_000e18; a[1] = 10_000e18;
        uint256 snap = vm.snapshotState();
        vm.prank(investmentManager);
        uint256[] memory s = vault.fulfillDeposits(c, a);
        vm.revertToState(snap);
        vm.startPrank(investmentManager);
        uint256 s0 = vault.fulfillDeposit(alice, 10_000e18);
        uint256 s1 = vault.fulfillDeposit(bob, 10_000e18);
        vm.stopPrank();
        assertApproxEqAbs(s[0], s0, 1);
        assertApproxEqAbs(s[1], s1, 1);
    }

    // ---------- Dismiss: cancel flows return exactly what was put in; no double claim ----------
    function test_dismiss_cancelFlowsNoDoubleClaim() public {
        vm.startPrank(alice);
        asset.approve(address(vault), type(uint256).max);
        vault.requestDeposit(10_000e18, alice, alice);
        vault.cancelDepositRequest(0, alice);
        vm.stopPrank();
        vm.prank(investmentManager);
        vm.expectRevert(); // cannot fulfill a cancelled deposit
        vault.fulfillDeposit(alice, 10_000e18);
        vm.prank(investmentManager);
        vault.fulfillCancelDepositRequest(alice);
        uint256 before = asset.balanceOf(alice);
        vm.prank(alice);
        vault.claimCancelDepositRequest(0, alice, alice);
        assertEq(asset.balanceOf(alice) - before, 10_000e18);
        vm.prank(alice);
        vm.expectRevert();
        vault.claimCancelDepositRequest(0, alice, alice);

        // redeem cancel
        uint256 bShares = depositFlow(bob, 10_000e18);
        requestRedeem(bob, bShares);
        vm.prank(bob);
        vault.cancelRedeemRequest(0, bob);
        vm.prank(investmentManager);
        vm.expectRevert(); // cannot fulfill a cancelled redeem
        vault.fulfillRedeem(bob, bShares);
        vm.prank(investmentManager);
        vault.fulfillCancelRedeemRequest(bob);
        vm.prank(bob);
        vault.claimCancelRedeemRequest(0, bob, bob);
        assertEq(shareToken.balanceOf(bob), bShares);
        // total assets/nav unaffected
        assertEq(vault.totalAssets(), 10_000e18);
    }

    // ---------- Dismiss: partial claims can't extract more than claimable (rounding) ----------
    function test_dismiss_partialClaimsCapped() public {
        depositFlow(carol, 7_777e18);
        vm.startPrank(alice);
        asset.approve(address(vault), type(uint256).max);
        vault.requestDeposit(3_333e18, alice, alice);
        vm.stopPrank();
        vm.prank(investmentManager);
        uint256 total = vault.fulfillDeposit(alice, 3_333e18);
        uint256 got;
        vm.startPrank(alice);
        // many small odd-sized claims to accumulate rounding in the claimer's favour
        for (uint256 i; i < 50; i++) {
            try vault.mint(1e18 + 7, alice, alice) returns (uint256) { got++; } catch {}
            try vault.deposit(1e18 + 3, alice, alice) returns (uint256) { got++; } catch {}
        }
        uint256 left = vault.maxMint(alice);
        if (left > 0) vault.mint(left, alice, alice);
        vm.stopPrank();
        assertEq(shareToken.balanceOf(alice), total, "exactly the fulfilled shares");
    }

    // ---------- Lead (QA): withdrawFromInvestment(type(uint256).max) overflows for <18-decimal assets ----------
    // (not run here: requires a 6-decimal investment vault; the CompleteFlow tests only pass with an 18-dec asset)
}
