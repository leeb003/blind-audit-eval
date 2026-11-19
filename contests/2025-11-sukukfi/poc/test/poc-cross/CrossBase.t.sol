// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {ERC7575VaultUpgradeable} from "../../src/ERC7575VaultUpgradeable.sol";
import {ShareTokenUpgradeable} from "../../src/ShareTokenUpgradeable.sol";
import {WERC7575ShareToken} from "../../src/WERC7575ShareToken.sol";
import {WERC7575Vault} from "../../src/WERC7575Vault.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Test} from "forge-std/Test.sol";

contract DecMock is ERC20 {
    uint8 private immutable _d;
    constructor(uint8 d) ERC20("Mock", "MCK") { _d = d; }
    function decimals() public view override returns (uint8) { return _d; }
    function mint(address to, uint256 amt) external { _mint(to, amt); }
}

/// Mirrors test/CompleteFlowWalkthrough.t.sol: upgradeable ShareToken + vault, real WERC7575 investment target.
abstract contract CrossBase is Test {
    address owner = makeAddr("owner");
    address im = makeAddr("investmentManager");
    address validator;
    uint256 validatorPk;
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    ShareTokenUpgradeable shareToken;
    WERC7575ShareToken invShare;

    function setUp() public virtual {
        (validator, validatorPk) = makeAddrAndKey("validator");
        vm.startPrank(owner);
        invShare = new WERC7575ShareToken("Investment USD", "iUSD");
        invShare.setValidator(validator);
        invShare.setKycAdmin(validator);
        invShare.setRevenueAdmin(validator);

        ShareTokenUpgradeable stImpl = new ShareTokenUpgradeable();
        shareToken = ShareTokenUpgradeable(address(new ERC1967Proxy(
            address(stImpl), abi.encodeWithSelector(ShareTokenUpgradeable.initialize.selector, "Shares", "SHR", owner))));
        shareToken.setInvestmentManager(im);
        vm.stopPrank();
    }

    /// Deploys an asset with `dec` decimals, its upgradeable vault and its WERC7575 investment vault; registers both.
    function addAsset(uint8 dec) internal returns (DecMock a, ERC7575VaultUpgradeable v, WERC7575Vault iv) {
        vm.startPrank(owner);
        a = new DecMock(dec);
        iv = new WERC7575Vault(address(a), invShare);
        invShare.registerVault(address(a), address(iv));
        ERC7575VaultUpgradeable impl = new ERC7575VaultUpgradeable();
        v = ERC7575VaultUpgradeable(address(new ERC1967Proxy(
            address(impl), abi.encodeWithSelector(ERC7575VaultUpgradeable.initialize.selector, IERC20(address(a)), address(shareToken), owner))));
        shareToken.registerVault(address(a), address(v));
        if (shareToken.getInvestmentShareToken() == address(0)) shareToken.setInvestmentShareToken(address(invShare));
        vm.stopPrank();
        vm.prank(validator);
        invShare.setKycVerified(address(shareToken), true);
    }

    function depositFlow(ERC7575VaultUpgradeable v, DecMock a, address user, uint256 amt) internal returns (uint256 shares) {
        a.mint(user, amt);
        vm.startPrank(user);
        a.approve(address(v), amt);
        v.requestDeposit(amt, user, user);
        vm.stopPrank();
        vm.prank(im);
        v.fulfillDeposit(user, amt);
        vm.prank(user);
        shares = v.deposit(amt, user);
    }

    function requestRedeem(ERC7575VaultUpgradeable v, address user, uint256 shares) internal {
        vm.prank(user);
        v.requestRedeem(shares, user, user);
    }

    function permitShareTokenSelf() internal {
        address st = address(shareToken);
        uint256 deadline = block.timestamp + 1 hours;
        bytes32 structHash = keccak256(abi.encode(
            keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"),
            st, st, type(uint256).max, invShare.nonces(st), deadline));
        bytes32 h = keccak256(abi.encodePacked("\x19\x01", invShare.DOMAIN_SEPARATOR(), structHash));
        (uint8 v_, bytes32 r, bytes32 s) = vm.sign(validatorPk, h);
        invShare.permit(st, st, type(uint256).max, deadline, v_, r, s);
    }
}
