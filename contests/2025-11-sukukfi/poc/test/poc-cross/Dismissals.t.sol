// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "./CrossBase.t.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IERC7575} from "../../src/interfaces/IERC7575.sol";

contract HookToken is ERC20 {
    address public target;
    bytes public data;
    bool public fired;
    bytes public lastRevert;
    constructor() ERC20("Hook", "HK") {}
    function mint(address to, uint256 amt) external { _mint(to, amt); }
    function arm(address t, bytes memory d) external { target = t; data = d; }
    function _update(address from, address to, uint256 v) internal override {
        super._update(from, to, v);
        if (target != address(0) && !fired) {
            fired = true;
            (bool ok, bytes memory ret) = target.call(data);
            if (!ok) lastRevert = ret;
        }
    }
}

contract NewVaultImpl is ERC7575VaultUpgradeable {
    function version() external pure returns (uint256) { return 2; }
}

/// Tests that disprove leads (PROCESS.md: no dismissal without a test attempt).
contract DismissalsTest is CrossBase {
    /// Lead: contracts deployed behind ERC1967Proxy have no upgrade path (no UUPSUpgradeable). DISPROVEN: custom upgradeTo.
    function test_dismiss_upgradeWorksAndStateSurvives() public {
        (DecMock a, ERC7575VaultUpgradeable v,) = addAsset(18);
        uint256 s = depositFlow(v, a, alice, 1000e18);
        NewVaultImpl impl2 = new NewVaultImpl();
        vm.prank(alice);
        vm.expectRevert();
        v.upgradeTo(address(impl2)); // non-owner blocked
        vm.prank(owner);
        v.upgradeTo(address(impl2));
        assertEq(NewVaultImpl(address(v)).version(), 2);
        assertEq(v.asset(), address(a));
        assertEq(shareToken.balanceOf(alice), s);
        assertEq(v.getInvestmentManager(), im);
    }

    /// Lead: implementation / proxy re-initialisation. DISPROVEN.
    function test_dismiss_initializersLocked() public {
        (DecMock a, ERC7575VaultUpgradeable v,) = addAsset(18);
        vm.expectRevert();
        v.initialize(a, address(shareToken), alice);
        ShareTokenUpgradeable impl = new ShareTokenUpgradeable();
        vm.expectRevert();
        impl.initialize("x", "x", alice);
        ERC7575VaultUpgradeable vimpl = new ERC7575VaultUpgradeable();
        vm.expectRevert();
        vimpl.initialize(a, address(shareToken), alice);
    }

    /// Lead: namespaced slots collide with OZ ERC-7201 slots or each other. DISPROVEN (distinct; note: not the ERC-7201 formula -> QA).
    function test_dismiss_storageSlotsDistinct() public pure {
        bytes32 v = keccak256("erc7575.vault.storage");
        bytes32 s = keccak256("erc7575.sharetoken.storage");
        bytes32 own = 0x9016d09d72d40fdae2fd8ceac6b6234c7706214fd39c1cd1e609a0528c199300; // OZ Ownable
        bytes32 own2 = 0x237e158222e3e6968b72b9db0d8043aacf074ad9f650f0d1606b4d82ee432c00; // OZ Ownable2Step
        bytes32 erc20 = 0x52c63247e1f47db19d5ce0460030c497f067ca4cebf71ba98eeadabe20bace00; // OZ ERC20
        bytes32 init = 0xf0c57e16840df040f15088dc2f81fe391c3923bec73e23a9662efc9c229c6a00; // OZ Initializable
        bytes32 rg = 0x9b779b17422d0df92223018b32b4d1fa46e071723d6817e2486d003becc55f00; // OZ ReentrancyGuard
        bytes32[7] memory all = [v, s, own, own2, erc20, init, rg];
        for (uint256 i; i < 7; i++) for (uint256 j = i + 1; j < 7; j++) assert(all[i] != all[j]);
        // ERC-7201 formula would be keccak256(abi.encode(uint256(keccak256(id)) - 1)) & ~0xff
        assert(v != (keccak256(abi.encode(uint256(keccak256("erc7575.vault.storage")) - 1)) & ~bytes32(uint256(0xff))));
    }

    /// Lead: round-trip rounding favours users for 6/8/18-decimal assets. DISPROVEN by fuzz: never get back more than deposited.
    function testFuzz_dismiss_roundTripNeverProfits(uint8 decSel, uint96 seed, uint96 amt) public {
        uint8 dec = decSel % 3 == 0 ? 6 : (decSel % 3 == 1 ? 8 : 18);
        (DecMock a, ERC7575VaultUpgradeable v,) = addAsset(dec);
        uint256 unit = 10 ** dec;
        depositFlow(v, a, bob, 1000 * unit + uint256(seed) % (1e9 * unit)); // existing holder
        // yield donation to move price off 1:1
        a.mint(address(v), uint256(seed) % (1e6 * unit));
        uint256 dep = 1000 * unit + uint256(amt) % (1e9 * unit);
        uint256 s = depositFlow(v, a, alice, dep);
        requestRedeem(v, alice, s);
        vm.prank(im);
        uint256 out = v.fulfillRedeem(alice, s);
        assertLe(out, dep);
    }

    /// Lead: cross-asset rounding arbitrage (deposit 6-dec, redeem 18-dec). DISPROVEN: normalized value never increases.
    function testFuzz_dismiss_crossAssetNoArb(uint96 amt) public {
        (DecMock usdc, ERC7575VaultUpgradeable vU,) = addAsset(6);
        (DecMock dai, ERC7575VaultUpgradeable vD,) = addAsset(18);
        depositFlow(vD, dai, bob, 1_000_000e18);
        uint256 dep = 1000e6 + uint256(amt) % 1e15;
        uint256 s = depositFlow(vU, usdc, alice, dep);
        requestRedeem(vD, alice, s);
        vm.prank(im);
        uint256 out = vD.fulfillRedeem(alice, s);
        assertLe(out, dep * 1e12);
    }

    /// Lead: first-depositor / donation inflation steals a later depositor's assets. DISPROVEN: min deposit (1000 tokens)
    /// + floor rounding keep victim loss <= 1 wei; attacker never profits.
    function test_dismiss_donationInflationUnprofitable() public {
        (DecMock a, ERC7575VaultUpgradeable v,) = addAsset(6);
        uint256 sAtk = depositFlow(v, a, bob, 1000e6);
        a.mint(bob, 1_000_000e6);
        vm.prank(bob);
        a.transfer(address(v), 1_000_000e6); // donation
        uint256 sVic = depositFlow(v, a, alice, 1000e6);
        assertGt(sVic, 0);
        // attacker's claim on assets vs what he put in
        uint256 atkValue = v.convertToAssets(sAtk);
        assertLe(atkValue, 1_001_000e6, "attacker never ends with more than he put in");
        assertGe(v.convertToAssets(sVic), 1000e6 - 1, "victim keeps value (loss <= 1 wei)");
    }

    /// Lead: ERC777-style hook token re-enters vault during requestDeposit (transfer happens before state update). DISPROVEN: nonReentrant.
    function test_dismiss_hookReentrancyBlocked() public {
        vm.startPrank(owner);
        HookToken h = new HookToken();
        ERC7575VaultUpgradeable impl = new ERC7575VaultUpgradeable();
        ERC7575VaultUpgradeable v = ERC7575VaultUpgradeable(address(new ERC1967Proxy(
            address(impl), abi.encodeWithSelector(ERC7575VaultUpgradeable.initialize.selector, IERC20(address(h)), address(shareToken), owner))));
        shareToken.registerVault(address(h), address(v));
        vm.stopPrank();
        h.mint(alice, 5000e18);
        vm.prank(alice);
        h.approve(address(v), type(uint256).max);
        // hook fires inside the transfer and tries to cancel/re-request from the same vault
        h.arm(address(v), abi.encodeWithSelector(v.cancelDepositRequest.selector, 0, alice));
        vm.prank(alice);
        v.requestDeposit(1000e18, alice, alice);
        assertTrue(h.fired());
        assertEq(bytes4(h.lastRevert()), bytes4(keccak256("ReentrancyGuardReentrantCall()")));
    }

    /// Lead: fee-on-transfer asset desyncs reserved accounting. DISPROVEN: SafeTokenTransfers balance-delta check reverts.
    function test_dismiss_feeOnTransferReverts() public {
        vm.startPrank(owner);
        FeeToken f = new FeeToken();
        ERC7575VaultUpgradeable impl = new ERC7575VaultUpgradeable();
        ERC7575VaultUpgradeable v = ERC7575VaultUpgradeable(address(new ERC1967Proxy(
            address(impl), abi.encodeWithSelector(ERC7575VaultUpgradeable.initialize.selector, IERC20(address(f)), address(shareToken), owner))));
        vm.stopPrank();
        f.mint(alice, 5000e18);
        vm.startPrank(alice);
        f.approve(address(v), type(uint256).max);
        vm.expectRevert(bytes4(keccak256("TransferAmountMismatch()")));
        v.requestDeposit(1000e18, alice, alice);
        vm.stopPrank();
    }

    /// Lead: a role on one contract reaches privileged ShareToken functions (mint/burn/vaultTransferFrom/spendAllowance/
    /// setOperatorFor) or vault admin setters. DISPROVEN for IM / vault owner / user.
    function test_dismiss_roleBoundaries() public {
        (, ERC7575VaultUpgradeable v,) = addAsset(18);
        address[3] memory who = [im, alice, validator];
        for (uint256 i; i < 3; i++) {
            vm.startPrank(who[i]);
            vm.expectRevert(); shareToken.mint(who[i], 1);
            vm.expectRevert(); shareToken.burn(bob, 1);
            vm.expectRevert(); shareToken.vaultTransferFrom(bob, who[i], 1);
            vm.expectRevert(); shareToken.spendAllowance(bob, who[i], 1);
            vm.expectRevert(); shareToken.setOperatorFor(bob, who[i], true);
            vm.expectRevert(); v.setInvestmentManager(who[i]);
            vm.expectRevert(); v.setInvestmentVault(IERC7575(address(v)));
            vm.expectRevert(); shareToken.registerVault(address(1), address(v));
            vm.stopPrank();
        }
    }
}



contract FeeToken is ERC20 {
    constructor() ERC20("Fee", "FEE") {}
    function mint(address to, uint256 amt) external { _mint(to, amt); }
    function _update(address from, address to, uint256 v) internal override {
        if (from != address(0) && to != address(0)) { super._update(from, address(0xdead), v / 100); v -= v / 100; }
        super._update(from, to, v);
    }
}
