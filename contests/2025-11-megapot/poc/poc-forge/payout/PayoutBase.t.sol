// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { Jackpot } from "../../contracts/Jackpot.sol";
import { JackpotLPManager } from "../../contracts/JackpotLPManager.sol";
import { JackpotTicketNFT } from "../../contracts/JackpotTicketNFT.sol";
import { GuaranteedMinimumPayoutCalculator } from "../../contracts/GuaranteedMinimumPayoutCalculator.sol";
import { ScaledEntropyProvider } from "../../contracts/ScaledEntropyProvider.sol";
import { IJackpot } from "../../contracts/interfaces/IJackpot.sol";
import { IJackpotLPManager } from "../../contracts/interfaces/IJackpotLPManager.sol";
import { IJackpotTicketNFT } from "../../contracts/interfaces/IJackpotTicketNFT.sol";
import { IScaledEntropyProvider } from "../../contracts/interfaces/IScaledEntropyProvider.sol";
import { IPayoutCalculator } from "../../contracts/interfaces/IPayoutCalculator.sol";
import { USDCMock } from "../../contracts/mocks/USDCMock.sol";
import { EntropyMock } from "../../contracts/mocks/EntropyMock.sol";

/// Full system with the REAL ScaledEntropyProvider on top of EntropyMock (Pyth stand-in).
/// Params mirror test/jackpot.spec.ts.
abstract contract PayoutBase is Test {
    address owner = address(this);
    address lp = makeAddr("lp");
    address pythProvider = makeAddr("pythProvider");

    USDCMock usdc;
    Jackpot jackpot;
    JackpotLPManager lpManager;
    JackpotTicketNFT nft;
    GuaranteedMinimumPayoutCalculator calc;
    EntropyMock pyth;
    ScaledEntropyProvider scaled;

    uint8 constant NORMAL_MAX = 30;
    uint64 nextSeq = 1;

    function _weights() internal pure returns (uint256[12] memory w, bool[12] memory minTiers) {
        w = [uint256(0), 0.17e18, 0, 0.13e18, 0.12e18, 0.05e18, 0.05e18, 0.02e18, 0.02e18, 0.01e18, 0.04e18, 0.39e18];
        for (uint256 i; i < 12; i++) minTiers[i] = w[i] > 0;
    }

    function deploySystem(uint256 lpDepositAmount) internal {
        usdc = new USDCMock(1e30, "USDC", "USDC");
        jackpot = new Jackpot(1 days, NORMAL_MAX, 5, 0.3e18, 0.2e18, 0.065e18, 0.05e18, 0.01e18, 2e6, 1e6, 5, 1_000_000);
        nft = new JackpotTicketNFT(IJackpot(address(jackpot)));
        lpManager = new JackpotLPManager(IJackpot(address(jackpot)));
        (uint256[12] memory w, bool[12] memory minTiers) = _weights();
        calc = new GuaranteedMinimumPayoutCalculator(IJackpot(address(jackpot)), 1e6, 0.2e18, minTiers, w);
        pyth = new EntropyMock(1);
        scaled = new ScaledEntropyProvider(address(pyth), pythProvider);

        jackpot.initialize(
            IERC20(address(usdc)),
            IJackpotLPManager(address(lpManager)),
            IJackpotTicketNFT(address(nft)),
            IScaledEntropyProvider(address(scaled)),
            IPayoutCalculator(address(calc))
        );
        jackpot.initializeLPDeposits(type(uint128).max);

        usdc.transfer(lp, lpDepositAmount);
        vm.startPrank(lp);
        usdc.approve(address(jackpot), lpDepositAmount);
        jackpot.lpDeposit(lpDepositAmount);
        vm.stopPrank();

        jackpot.initializeJackpot(block.timestamp + 1 days);
        vm.deal(address(this), 1000 ether);
    }

    /// runJackpot + Pyth reveal through the real ScaledEntropyProvider
    function settle(bytes32 pythRandom) internal {
        Jackpot.DrawingState memory ds = jackpot.getDrawingState(jackpot.currentDrawingId());
        vm.warp(ds.drawingTime + 1);
        uint256 fee = jackpot.getEntropyCallbackFee();
        jackpot.runJackpot{value: fee}();
        pyth.triggerCallback(nextSeq++, pythProvider, pythRandom);
    }

    function unpackWinning(uint256 drawingId) internal view returns (uint8[] memory normals, uint8 bonus) {
        Jackpot.DrawingState memory ds = jackpot.getDrawingState(drawingId);
        return jackpot.getUnpackedTicket(drawingId, ds.winningTicket);
    }

    receive() external payable {}
}
