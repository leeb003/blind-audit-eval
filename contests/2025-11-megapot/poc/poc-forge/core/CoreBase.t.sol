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

/// Mirrors utils/test/jackpotFixture.ts deployment parameters.
abstract contract CoreBase is Test {
    address owner = makeAddr("owner");
    address lp = makeAddr("lp");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address ref1 = makeAddr("ref1");

    ReentrantUSDCMock usdc;
    Jackpot jackpot;
    JackpotLPManager lpManager;
    JackpotTicketNFT nft;
    GuaranteedMinimumPayoutCalculator calc;
    ScaledEntropyProviderMock entropy;

    uint256 constant ENTROPY_FEE = 0.00005 ether;

    function setUp() public virtual {
        vm.warp(1_700_000_000);
        vm.startPrank(owner);
        usdc = new ReentrantUSDCMock(1_000_000_000e6, "USDC", "USDC");
        jackpot = new Jackpot(
            1 days,       // drawingDurationInSeconds
            30,           // normalBallMax
            5,            // bonusballMin
            0.3 ether,    // lpEdgeTarget
            0.2 ether,    // reserveRatio
            0.065 ether,  // referralFee
            0.05 ether,   // referralWinShare
            0.01 ether,   // protocolFee
            1e6,          // protocolFeeThreshold
            1e6,          // ticketPrice
            5,            // maxReferrers
            10_000_000    // entropyBaseGasLimit
        );
        nft = new JackpotTicketNFT(IJackpot(address(jackpot)));
        lpManager = new JackpotLPManager(IJackpot(address(jackpot)));
        bool[12] memory minTiers = [false, true, false, true, true, true, true, true, true, true, true, true];
        uint256[12] memory weights = [
            uint256(0), 0.17 ether, 0, 0.13 ether, 0.12 ether, 0.05 ether,
            0.05 ether, 0.02 ether, 0.02 ether, 0.01 ether, 0.04 ether, 0.39 ether
        ];
        calc = new GuaranteedMinimumPayoutCalculator(IJackpot(address(jackpot)), 1e6, 0.2 ether, minTiers, weights);
        entropy = new ScaledEntropyProviderMock(ENTROPY_FEE, address(jackpot), Jackpot.scaledEntropyCallback.selector);

        jackpot.initialize(
            IERC20(address(usdc)),
            IJackpotLPManager(address(lpManager)),
            IJackpotTicketNFT(address(nft)),
            IScaledEntropyProvider(address(entropy)),
            IPayoutCalculator(address(calc))
        );
        jackpot.initializeLPDeposits(100_000_000e6);

        usdc.transfer(lp, 100_000_000e6);
        usdc.transfer(alice, 1_000_000e6);
        usdc.transfer(bob, 1_000_000e6);
        vm.stopPrank();

        vm.startPrank(lp);
        usdc.approve(address(jackpot), type(uint256).max);
        jackpot.lpDeposit(2_000_000e6);
        vm.stopPrank();

        vm.prank(owner);
        jackpot.initializeJackpot(block.timestamp + 1 days);

        vm.prank(alice);
        usdc.approve(address(jackpot), type(uint256).max);
        vm.prank(bob);
        usdc.approve(address(jackpot), type(uint256).max);
        vm.deal(address(this), 10 ether);
    }

    function ticket(uint8 a, uint8 b, uint8 c, uint8 d, uint8 e, uint8 bonus) internal pure returns (IJackpot.Ticket memory t) {
        t.normals = new uint8[](5);
        t.normals[0] = a; t.normals[1] = b; t.normals[2] = c; t.normals[3] = d; t.normals[4] = e;
        t.bonusball = bonus;
    }

    function buy(address who, IJackpot.Ticket[] memory ts, address[] memory refs, uint256[] memory splits)
        internal returns (uint256[] memory ids)
    {
        vm.prank(who);
        ids = jackpot.buyTickets(ts, who, refs, splits, bytes32(0));
    }

    function buyOne(address who, uint8 seed, bool withReferral) internal returns (uint256 id) {
        IJackpot.Ticket[] memory ts = new IJackpot.Ticket[](1);
        ts[0] = ticket(1, 2, 3, 4, uint8(5 + seed % 20), 1);
        address[] memory refs = new address[](withReferral ? 1 : 0);
        uint256[] memory splits = new uint256[](withReferral ? 1 : 0);
        if (withReferral) { refs[0] = ref1; splits[0] = 1e18; }
        id = buy(who, ts, refs, splits)[0];
    }

    /// Runs the current drawing and settles it with the given winning numbers.
    function settle(uint256[] memory normals, uint256 bonus) internal {
        vm.warp(jackpot.getDrawingState(jackpot.currentDrawingId()).drawingTime + 1);
        jackpot.runJackpot{value: 1 ether}();
        uint256[][] memory rn = new uint256[][](2);
        rn[0] = normals;
        rn[1] = new uint256[](1);
        rn[1][0] = bonus;
        entropy.randomnessCallback(rn);
    }

    function defaultNormals() internal pure returns (uint256[] memory n) {
        n = new uint256[](5);
        n[0] = 26; n[1] = 27; n[2] = 28; n[3] = 29; n[4] = 30;
    }

    receive() external payable {}
}
