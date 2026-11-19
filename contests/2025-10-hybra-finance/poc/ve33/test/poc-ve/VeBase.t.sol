// SPDX-License-Identifier: MIT
pragma solidity 0.8.13;

import "forge-std/Test.sol";
import {C4PoCTestbed} from "../C4PoCTestbed.t.sol";
import {HybraTimeLibrary} from "../../contracts/libraries/HybraTimeLibrary.sol";
import {IVotingEscrow} from "../../contracts/interfaces/IVotingEscrow.sol";

contract MockTok {
    string public name;
    string public symbol;
    uint8 public decimals = 18;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    uint256 public totalSupply;
    constructor(string memory n) { name = n; symbol = n; }
    function mint(address to, uint256 a) external { balanceOf[to] += a; totalSupply += a; }
    function approve(address s, uint256 a) external returns (bool) { allowance[msg.sender][s] = a; return true; }
    function transfer(address to, uint256 a) external returns (bool) { balanceOf[msg.sender] -= a; balanceOf[to] += a; return true; }
    function transferFrom(address f, address to, uint256 a) external returns (bool) {
        if (allowance[f][msg.sender] != type(uint256).max) allowance[f][msg.sender] -= a;
        balanceOf[f] -= a; balanceOf[to] += a; return true;
    }
}

/// Shared helpers for VotingEscrow PoCs built on the official C4 testbed.
abstract contract VeBase is C4PoCTestbed {
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    uint256 WEEK = 1800; // HybraTimeLibrary.WEEK
    uint256 MAXTIME = 86400 * 365 * 2; // HybraTimeLibrary.MAX_LOCK_DURATION

    address pool;
    address gauge;

    function setUp() public virtual override {
        super.setUp();
        hybr.transfer(alice, 10_000_000e18);
        hybr.transfer(bob, 10_000_000e18);
        vm.prank(alice);
        hybr.approve(address(votingEscrow), type(uint256).max);
        vm.prank(bob);
        hybr.approve(address(votingEscrow), type(uint256).max);
    }

    /// Creates a volatile pair HYBR/X with a live gauge + bribes so veNFTs can vote.
    function _setupGauge() internal {
        bribeFactoryV3.initialize(address(voter), address(gaugeManager), address(permissionsRegistry), address(tokenHandler));
        MockTok x = new MockTok("X");
        permissionsRegistry.setRoleFor(address(this), "GOVERNANCE");
        tokenHandler.whitelistToken(address(hybr));
        tokenHandler.whitelistToken(address(x));
        tokenHandler.whitelistConnector(address(hybr));
        pool = thenaFiFactory.createPair(address(hybr), address(x), false);
        (gauge,,) = gaugeManager.createGauge(pool, 0);
    }

    /// Warp into the voting window of the next epoch.
    function _toVoteWindow() internal {
        uint256 next = HybraTimeLibrary.epochNext(block.timestamp);
        vm.warp(next + HybraTimeLibrary.NO_VOTING_WINDOW + 1);
    }

    function _vote(address who, uint256 id) internal {
        address[] memory pools = new address[](1);
        pools[0] = pool;
        uint256[] memory w = new uint256[](1);
        w[0] = 1;
        vm.prank(who);
        voter.vote(id, pools, w);
    }

    function _lock(address who, uint256 amt, uint256 dur) internal returns (uint256 id) {
        vm.prank(who);
        id = votingEscrow.create_lock(amt, dur);
    }
}
