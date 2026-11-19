// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import { Jackpot } from "../../contracts/Jackpot.sol";
import { IJackpot } from "../../contracts/interfaces/IJackpot.sol";
import { JackpotLPManager } from "../../contracts/JackpotLPManager.sol";
import { JackpotTicketNFT } from "../../contracts/JackpotTicketNFT.sol";
import { GuaranteedMinimumPayoutCalculator } from "../../contracts/GuaranteedMinimumPayoutCalculator.sol";
import { ScaledEntropyProviderMock } from "../../contracts/mocks/ScaledEntropyProviderMock.sol";
import { ReentrantUSDCMock } from "../../contracts/mocks/ReentrantUSDCMock.sol";
import { IJackpotLPManager } from "../../contracts/interfaces/IJackpotLPManager.sol";
import { IJackpotTicketNFT } from "../../contracts/interfaces/IJackpotTicketNFT.sol";
import { IScaledEntropyProvider } from "../../contracts/interfaces/IScaledEntropyProvider.sol";
import { IPayoutCalculator } from "../../contracts/interfaces/IPayoutCalculator.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// Mirrors utils/test/jackpotFixture.ts deployment params + the C4PoC.spec.ts setup.
abstract contract LPBase is Test {
    address owner = makeAddr("owner");
    address lp = makeAddr("lp");
    address buyer = makeAddr("buyer");
    address referrer = makeAddr("referrer");

    ReentrantUSDCMock usdc;
    Jackpot jackpot;
    JackpotLPManager lpManager;
    JackpotTicketNFT nft;
    GuaranteedMinimumPayoutCalculator calc;
    ScaledEntropyProviderMock entropy;

    uint256 constant U = 1e6;

    function _weights() internal pure returns (uint256[12] memory w) {
        w = [uint256(0), 0.17e18, 0, 0.13e18, 0.12e18, 0.05e18, 0.05e18, 0.02e18, 0.02e18, 0.01e18, 0.04e18, 0.39e18];
    }

    function _minTiers() internal pure returns (bool[12] memory t) {
        t = [false, true, false, true, true, true, true, true, true, true, true, true];
    }

    function _newCalc() internal returns (GuaranteedMinimumPayoutCalculator c) {
        vm.prank(owner);
        c = new GuaranteedMinimumPayoutCalculator(IJackpot(address(jackpot)), 1 * U, 0.2e18, _minTiers(), _weights());
    }

    function setUp() public virtual {
        vm.startPrank(owner);
        usdc = new ReentrantUSDCMock(1_000_000_000 * U, "USDC", "USDC");
        jackpot = new Jackpot(1 days, 30, 5, 0.3e18, 0.2e18, 0.065e18, 0.05e18, 0.01e18, 1 * U, 1 * U, 5, 10_000_000);
        nft = new JackpotTicketNFT(IJackpot(address(jackpot)));
        lpManager = new JackpotLPManager(IJackpot(address(jackpot)));
        vm.stopPrank();
        calc = _newCalc();
        vm.startPrank(owner);
        entropy = new ScaledEntropyProviderMock(0.00005 ether, address(jackpot), jackpot.scaledEntropyCallback.selector);
        jackpot.initialize(
            IERC20(address(usdc)),
            IJackpotLPManager(address(lpManager)),
            IJackpotTicketNFT(address(nft)),
            IScaledEntropyProvider(address(entropy)),
            IPayoutCalculator(address(calc))
        );
        jackpot.initializeLPDeposits(10_000_000 * U);
        usdc.transfer(lp, 100_000_000 * U);
        usdc.transfer(buyer, 100_000 * U);
        vm.stopPrank();

        vm.startPrank(lp);
        usdc.approve(address(jackpot), type(uint256).max);
        jackpot.lpDeposit(1_000_000 * U);
        vm.stopPrank();

        vm.prank(owner);
        jackpot.initializeJackpot(block.timestamp + 1 days);

        vm.prank(buyer);
        usdc.approve(address(jackpot), type(uint256).max);
        vm.deal(address(this), 100 ether);
    }

    function _ticket(uint8 a, uint8 b, uint8 c, uint8 d, uint8 e, uint8 bonus) internal pure returns (IJackpot.Ticket memory t) {
        t.normals = new uint8[](5);
        t.normals[0] = a; t.normals[1] = b; t.normals[2] = c; t.normals[3] = d; t.normals[4] = e;
        t.bonusball = bonus;
    }

    function _buy(IJackpot.Ticket memory t, uint256 n, bool withReferrer) internal returns (uint256[] memory ids) {
        IJackpot.Ticket[] memory ts = new IJackpot.Ticket[](n);
        for (uint256 i; i < n; i++) ts[i] = t;
        address[] memory refs = new address[](withReferrer ? 1 : 0);
        uint256[] memory splits = new uint256[](withReferrer ? 1 : 0);
        if (withReferrer) { refs[0] = referrer; splits[0] = 1e18; }
        vm.prank(buyer);
        ids = jackpot.buyTickets(ts, buyer, refs, splits, bytes32(0));
    }

    /// runs the current drawing with the given winning numbers
    function _draw(uint256[5] memory normals, uint256 bonus) internal {
        vm.warp(jackpot.getDrawingState(jackpot.currentDrawingId()).drawingTime + 1);
        jackpot.runJackpot{ value: jackpot.getEntropyCallbackFee() }();
        uint256[][] memory r = new uint256[][](2);
        r[0] = new uint256[](5);
        for (uint256 i; i < 5; i++) r[0][i] = normals[i];
        r[1] = new uint256[](1);
        r[1][0] = bonus;
        entropy.randomnessCallback(r);
    }

    receive() external payable {}
}
