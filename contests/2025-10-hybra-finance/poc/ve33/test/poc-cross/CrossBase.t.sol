// SPDX-License-Identifier: MIT
pragma solidity 0.8.13;

import "forge-std/Test.sol";
import {C4PoCTestbed} from "../C4PoCTestbed.t.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {HybraTimeLibrary} from "../../contracts/libraries/HybraTimeLibrary.sol";
import {GaugeV2} from "../../contracts/GaugeV2.sol";

contract MockToken is ERC20 {
    constructor(string memory n) ERC20(n, n) { _mint(msg.sender, 1e30); }
}

/// Testbed + the wiring a real deployment needs to create a basic-pair gauge and vote.
abstract contract CrossBase is C4PoCTestbed {
    MockToken usdx;
    address pair;
    GaugeV2 gauge;
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    function setUp() public virtual override {
        super.setUp();
        permissionsRegistry.setRoleFor(address(this), "GOVERNANCE");
        bribeFactoryV3.initialize(address(voter), address(gaugeManager), address(permissionsRegistry), address(tokenHandler));
        gaugeFactory.setRHYBR(address(rewardHybr));
        gHybr.setVoter(address(voter));

        usdx = new MockToken("USDX");
        tokenHandler.whitelistToken(address(hybr));
        tokenHandler.whitelistToken(address(usdx));
        tokenHandler.whitelistConnector(address(usdx));
        pair = thenaFiFactory.createPair(address(hybr), address(usdx), false);
        (address g,,) = gaugeManager.createGauge(pair, 0);
        gauge = GaugeV2(g);

        hybr.transfer(alice, 10_000e18);
        hybr.transfer(bob, 10_000e18);
    }

    function epochStart() internal view returns (uint256) { return HybraTimeLibrary.epochStart(block.timestamp); }
    function warpToNextEpoch(uint256 offset) internal { vm.warp(HybraTimeLibrary.epochNext(block.timestamp) + offset); }
}
