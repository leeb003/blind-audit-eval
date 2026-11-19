// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {ERC20Faucet6} from "../../src/ERC20Faucet6.sol";
import {WERC7575ShareToken} from "../../src/WERC7575ShareToken.sol";
import {WERC7575Vault} from "../../src/WERC7575Vault.sol";
import {Test} from "forge-std/Test.sol";

/// Mirrors test/WERC7575.t.sol setup, with a 6-decimal asset (USDC-like).
abstract contract SettleBase is Test {
    WERC7575Vault vault;
    WERC7575ShareToken shareToken;
    ERC20Faucet6 usdc;

    address owner = address(this);
    address validator;
    uint256 validatorPk;
    address alice;
    uint256 alicePk;
    address bob = makeAddr("bob");
    address carol = makeAddr("carol");
    address attacker = makeAddr("attacker");

    function setUp() public virtual {
        (validator, validatorPk) = makeAddrAndKey("validator");
        (alice, alicePk) = makeAddrAndKey("alice");
        usdc = new ERC20Faucet6("USDC", "USDC", 1e9 * 1e6);
        shareToken = new WERC7575ShareToken("wUSD", "WUSD");
        vault = new WERC7575Vault(address(usdc), shareToken);
        shareToken.registerVault(address(usdc), address(vault));
        shareToken.setValidator(validator);
        shareToken.setKycAdmin(validator);
        shareToken.setRevenueAdmin(validator);
        vm.startPrank(validator);
        shareToken.setKycVerified(alice, true);
        shareToken.setKycVerified(bob, true);
        shareToken.setKycVerified(carol, true);
        vm.stopPrank();
        usdc.transfer(alice, 1_000_000e6);
        usdc.transfer(bob, 1_000_000e6);
    }

    function depositFor(address who, uint256 assets) internal returns (uint256 shares) {
        vm.startPrank(who);
        usdc.approve(address(vault), assets);
        shares = vault.deposit(assets, who);
        vm.stopPrank();
    }

    /// Validator-signed self-allowance permit (the documented way users get transfer rights).
    function grantSelfAllowance(address who, uint256 value) internal {
        uint256 deadline = block.timestamp + 1 days;
        bytes32 digest = _permitDigest(who, who, value, shareToken.nonces(who), deadline);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(validatorPk, digest);
        shareToken.permit(who, who, value, deadline, v, r, s);
    }

    function _permitDigest(address o, address sp, uint256 value, uint256 nonce, uint256 deadline) internal view returns (bytes32) {
        bytes32 structHash = keccak256(
            abi.encode(keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"), o, sp, value, nonce, deadline)
        );
        return keccak256(abi.encodePacked("\x19\x01", shareToken.DOMAIN_SEPARATOR(), structHash));
    }
}
