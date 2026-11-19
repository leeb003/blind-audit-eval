// SPDX-License-Identifier: MIT
pragma solidity 0.8.13;

import "forge-std/Test.sol";
import {C4PoCTestbed} from "../C4PoCTestbed.t.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {GaugeV2} from "../../contracts/GaugeV2.sol";
import {HybraTimeLibrary} from "../../contracts/libraries/HybraTimeLibrary.sol";

contract MockToken is ERC20 {
    constructor(string memory n) ERC20(n, n) {}
    function mint(address to, uint256 a) external { _mint(to, a); }
}

interface IPairMin {
    function mint(address to) external returns (uint256);
}

/// Shared setup: 3 classic pools with gauges, voters with max locks.
abstract contract VoterBase is C4PoCTestbed {
    uint256 constant WEEK = 1800;
    MockToken tA;
    MockToken tB;
    MockToken tC;
    MockToken tD;
    address[] pairs;
    address[] gauges_;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address carol = makeAddr("carol");

    function setUp() public virtual override {
        vm.warp(1_700_000_000);
        super.setUp();
        bribeFactoryV3.initialize(address(voter), address(gaugeManager), address(permissionsRegistry), address(tokenHandler));
        permissionsRegistry.setRoleFor(address(this), "GOVERNANCE");

        tA = new MockToken("A");
        tB = new MockToken("B");
        tC = new MockToken("C");
        tD = new MockToken("D");
        address[] memory wl = new address[](4);
        wl[0] = address(tA); wl[1] = address(tB); wl[2] = address(tC); wl[3] = address(tD);
        tokenHandler.whitelistTokens(wl);
        tokenHandler.whitelistConnector(address(tA));

        MockToken[3] memory others = [tB, tC, tD];
        for (uint256 i; i < 3; i++) {
            address p = thenaFiFactory.createPair(address(tA), address(others[i]), false);
            pairs.push(p);
            (address g,,) = gaugeManager.createGauge(p, 0);
            gauges_.push(g);
        }

        hybr.transfer(alice, 1_000_000e18);
        hybr.transfer(bob, 1_000_000e18);
        hybr.transfer(carol, 10_000_000e18);
    }

    function lock(address who, uint256 amount) internal returns (uint256 id) {
        vm.startPrank(who);
        hybr.approve(address(votingEscrow), amount);
        id = votingEscrow.create_lock(amount, HybraTimeLibrary.MAX_LOCK_DURATION);
        vm.stopPrank();
    }

    function voteFor(address who, uint256 id, address pool) internal {
        address[] memory p = new address[](1);
        p[0] = pool;
        uint256[] memory w = new uint256[](1);
        w[0] = 1e18;
        vm.roll(block.number + 1);
        vm.prank(who);
        voter.vote(id, p, w);
    }

    /// make sure we are inside the current epoch's voting window (never warps backwards)
    function toVoteWindow() internal {
        uint256 vs = HybraTimeLibrary.epochVoteStart(block.timestamp);
        if (block.timestamp <= vs) vm.warp(vs + 1);
    }

    /// warp to `offset` seconds into the next epoch
    function toNextEpoch(uint256 offset) internal {
        vm.warp(HybraTimeLibrary.epochNext(block.timestamp) + offset);
    }

    function distributeOne(address g) internal {
        address[] memory gs = new address[](1);
        gs[0] = g;
        gaugeManager.distribute(gs);
    }

    function lp(address who, uint256 pairIdx, uint256 amt) internal returns (uint256 liq) {
        address p = pairs[pairIdx];
        MockToken other = pairIdx == 0 ? tB : (pairIdx == 1 ? tC : tD);
        tA.mint(p, amt);
        other.mint(p, amt);
        liq = IPairMin(p).mint(who);
    }
}
