// SPDX-License-Identifier: MIT
pragma solidity 0.8.13;

import "forge-std/Test.sol";
import {C4PoCTestbed} from "../C4PoCTestbed.t.sol";
import {HybraTimeLibrary} from "../../contracts/libraries/HybraTimeLibrary.sol";

abstract contract GHybrBase is C4PoCTestbed {
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address feeTeam = makeAddr("feeTeam");

    function setUp() public virtual override {
        super.setUp();
        gHybr.setTeam(feeTeam);
        votingEscrow.toggleSplit(address(gHybr), true); // deployer is VE team
        hybr.transfer(alice, 10_000_000e18);
        hybr.transfer(bob, 10_000_000e18);
        vm.prank(alice); hybr.approve(address(gHybr), type(uint256).max);
        vm.prank(bob); hybr.approve(address(gHybr), type(uint256).max);
    }

    function dep(address who, uint256 amt) internal returns (uint256 shares) {
        uint256 b = gHybr.balanceOf(who);
        vm.prank(who);
        gHybr.deposit(amt, who);
        shares = gHybr.balanceOf(who) - b;
    }

    /// warp into the gHYBR withdraw window of the current epoch (or next)
    function toWithdrawWindow() internal {
        uint256 start = HybraTimeLibrary.epochStart(block.timestamp);
        uint256 target = start + gHybr.head_not_withdraw_time() + 1;
        if (target <= block.timestamp) target += HybraTimeLibrary.WEEK;
        vm.warp(target);
    }

    function valueOf(address who) internal view returns (uint256) {
        return gHybr.calculateAssets(gHybr.balanceOf(who));
    }
}
