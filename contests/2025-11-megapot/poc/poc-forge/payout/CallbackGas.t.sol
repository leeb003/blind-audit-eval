// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import "./PayoutBase.t.sol";

/// Measure entropy callback gas vs the gas limit the Jackpot requests from Pyth.
contract CallbackGasTest is PayoutBase {
    function _measure(uint256 lpAmount, uint256 ticketsToBuy) internal returns (uint256 used, uint256 limit, uint8 bmax) {
        deploySystem(lpAmount);
        uint256 id = jackpot.currentDrawingId();
        Jackpot.DrawingState memory ds = jackpot.getDrawingState(id);
        bmax = ds.bonusballMax;
        if (ticketsToBuy > 0) {
            address buyer = makeAddr("buyer");
            usdc.transfer(buyer, ticketsToBuy * 1e6);
            IJackpot.Ticket[] memory t = new IJackpot.Ticket[](ticketsToBuy);
            for (uint256 i; i < ticketsToBuy; i++) {
                uint8[] memory n = new uint8[](5);
                for (uint8 k; k < 5; k++) n[k] = uint8(1 + (i * 7 + k * 5) % 30);
                // make unique-ish sets; skip collisions by shifting
                n[0] = uint8(1 + (i % 26)); n[1] = n[0] + 1; n[2] = n[0] + 2; n[3] = n[0] + 3; n[4] = n[0] + 4;
                t[i] = IJackpot.Ticket({normals: n, bonusball: uint8(1 + i % bmax)});
            }
            vm.startPrank(buyer);
            usdc.approve(address(jackpot), type(uint256).max);
            jackpot.buyTickets(t, buyer, new address[](0), new uint256[](0), bytes32(0));
            vm.stopPrank();
        }
        limit = uint256(jackpot.entropyBaseGasLimit()) + uint256(jackpot.entropyVariableGasLimit()) * bmax;
        vm.warp(ds.drawingTime + 1);
        jackpot.runJackpot{value: jackpot.getEntropyCallbackFee()}();
        uint256 g = gasleft();
        pyth.triggerCallback(nextSeq++, pythProvider, keccak256("r"));
        used = g - gasleft();
    }

    function test_gas_smallPool() public {
        (uint256 used, uint256 limit, uint8 b) = _measure(100_000e6, 50);
        emit log_named_uint("bonusballMax", b); emit log_named_uint("callback gas", used); emit log_named_uint("gas limit", limit);
    }
    function test_gas_largePool() public {
        (uint256 used, uint256 limit, uint8 b) = _measure(3_675_000e6, 50);
        emit log_named_uint("bonusballMax", b); emit log_named_uint("callback gas", used); emit log_named_uint("gas limit", limit);
    }
}
