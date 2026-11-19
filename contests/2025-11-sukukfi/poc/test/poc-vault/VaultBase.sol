// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {ERC7575VaultUpgradeable} from "../../src/ERC7575VaultUpgradeable.sol";
import {ShareTokenUpgradeable} from "../../src/ShareTokenUpgradeable.sol";
import {WERC7575ShareToken} from "../../src/WERC7575ShareToken.sol";
import {WERC7575Vault} from "../../src/WERC7575Vault.sol";
import {MockAsset} from "../MockAsset.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Test} from "forge-std/Test.sol";

/// Mirrors test/CompleteFlowWalkthrough.t.sol setup (real WERC7575Vault as investment target).
abstract contract VaultBase is Test {
    MockAsset asset;
    WERC7575ShareToken investmentShareToken;
    WERC7575Vault investmentVault;
    ShareTokenUpgradeable shareToken;
    ERC7575VaultUpgradeable vault;

    address owner = makeAddr("owner");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address carol = makeAddr("carol");
    address investmentManager = makeAddr("investmentManager");
    address validator = makeAddr("validator");

    function setUp() public virtual {
        vm.startPrank(owner);
        asset = new MockAsset();
        investmentShareToken = new WERC7575ShareToken("Investment USD", "iUSD");
        investmentVault = new WERC7575Vault(address(asset), investmentShareToken);
        investmentShareToken.registerVault(address(asset), address(investmentVault));
        investmentShareToken.setValidator(validator);
        investmentShareToken.setKycAdmin(validator);
        investmentShareToken.setRevenueAdmin(validator);

        ShareTokenUpgradeable stImpl = new ShareTokenUpgradeable();
        shareToken = ShareTokenUpgradeable(address(new ERC1967Proxy(
            address(stImpl), abi.encodeWithSelector(ShareTokenUpgradeable.initialize.selector, "S", "S", owner))));
        ERC7575VaultUpgradeable vImpl = new ERC7575VaultUpgradeable();
        vault = ERC7575VaultUpgradeable(address(new ERC1967Proxy(
            address(vImpl), abi.encodeWithSelector(ERC7575VaultUpgradeable.initialize.selector, IERC20(address(asset)), address(shareToken), owner))));
        shareToken.registerVault(address(asset), address(vault));
        shareToken.setInvestmentManager(investmentManager);
        shareToken.setInvestmentShareToken(address(investmentShareToken));
        vm.stopPrank();

        vm.prank(validator);
        investmentShareToken.setKycVerified(address(shareToken), true);
        _permitSelfAllowance();

        asset.mint(alice, 1_000_000e18);
        asset.mint(bob, 1_000_000e18);
        asset.mint(carol, 1_000_000e18);
    }

    function _permitSelfAllowance() internal {
        address st = address(shareToken);
        uint256 deadline = block.timestamp + 1 hours;
        bytes32 structHash = keccak256(abi.encode(
            keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"),
            st, st, type(uint256).max, investmentShareToken.nonces(st), deadline));
        bytes32 h = keccak256(abi.encodePacked("\x19\x01", investmentShareToken.DOMAIN_SEPARATOR(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(uint256(keccak256("validator")), h);
        investmentShareToken.permit(st, st, type(uint256).max, deadline, v, r, s);
    }

    /// request -> fulfill -> claim; returns shares received
    function depositFlow(address user, uint256 assets) internal returns (uint256 shares) {
        vm.startPrank(user);
        asset.approve(address(vault), assets);
        vault.requestDeposit(assets, user, user);
        vm.stopPrank();
        vm.prank(investmentManager);
        vault.fulfillDeposit(user, assets);
        vm.prank(user);
        shares = vault.deposit(assets, user);
    }

    function requestRedeem(address user, uint256 shares) internal {
        vm.prank(user);
        vault.requestRedeem(shares, user, user);
    }

    function fulfillRedeem(address user, uint256 shares) internal returns (uint256 assets) {
        vm.prank(investmentManager);
        assets = vault.fulfillRedeem(user, shares);
    }
}
