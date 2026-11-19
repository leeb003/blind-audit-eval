// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import { Jackpot } from "../../contracts/Jackpot.sol";
import { JackpotLPManager } from "../../contracts/JackpotLPManager.sol";
import { JackpotTicketNFT } from "../../contracts/JackpotTicketNFT.sol";
import { JackpotBridgeManager } from "../../contracts/JackpotBridgeManager.sol";
import { GuaranteedMinimumPayoutCalculator } from "../../contracts/GuaranteedMinimumPayoutCalculator.sol";
import { ScaledEntropyProviderMock } from "../../contracts/mocks/ScaledEntropyProviderMock.sol";
import { ReentrantUSDCMock } from "../../contracts/mocks/ReentrantUSDCMock.sol";
import { IJackpot } from "../../contracts/interfaces/IJackpot.sol";
import { IJackpotLPManager } from "../../contracts/interfaces/IJackpotLPManager.sol";
import { IJackpotTicketNFT } from "../../contracts/interfaces/IJackpotTicketNFT.sol";
import { IScaledEntropyProvider } from "../../contracts/interfaces/IScaledEntropyProvider.sol";
import { IPayoutCalculator } from "../../contracts/interfaces/IPayoutCalculator.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// Mirrors utils/test/jackpotFixture.ts + the C4PoC.spec.ts beforeEach.
abstract contract BridgeSetup is Test {
    uint256 constant USDC = 1e6;

    address owner = address(this);
    address lp = makeAddr("lp");
    address buyer = makeAddr("buyer");
    address referrer = makeAddr("referrer");

    ReentrantUSDCMock usdc;
    Jackpot jackpot;
    JackpotTicketNFT nft;
    JackpotLPManager lpManager;
    GuaranteedMinimumPayoutCalculator payout;
    ScaledEntropyProviderMock entropy;
    JackpotBridgeManager bridge;

    function setUp() public virtual {
        usdc = new ReentrantUSDCMock(1_000_000_000 * USDC, "USDC", "USDC");
        jackpot = new Jackpot(
            1 days, 30, 5, 0.3e18, 0.2e18, 0.065e18, 0.05e18, 0.01e18, 1 * USDC, 1 * USDC, 5, 10_000_000
        );
        nft = new JackpotTicketNFT(IJackpot(address(jackpot)));
        lpManager = new JackpotLPManager(IJackpot(address(jackpot)));

        bool[12] memory minTiers = [false, true, false, true, true, true, true, true, true, true, true, true];
        uint256[12] memory weights = [
            uint256(0), 0.17e18, 0, 0.13e18, 0.12e18, 0.05e18, 0.05e18, 0.02e18, 0.02e18, 0.01e18, 0.04e18, 0.39e18
        ];
        payout = new GuaranteedMinimumPayoutCalculator(IJackpot(address(jackpot)), 1 * USDC, 0.2e18, minTiers, weights);
        entropy = new ScaledEntropyProviderMock(0.00005 ether, address(jackpot), jackpot.scaledEntropyCallback.selector);

        jackpot.initialize(
            IERC20(address(usdc)),
            IJackpotLPManager(address(lpManager)),
            IJackpotTicketNFT(address(nft)),
            IScaledEntropyProvider(address(entropy)),
            IPayoutCalculator(address(payout))
        );
        jackpot.initializeLPDeposits(10_000_000 * USDC);
        usdc.approve(address(jackpot), 1_000_000 * USDC);
        jackpot.lpDeposit(1_000_000 * USDC);
        jackpot.initializeJackpot(block.timestamp + 1 days);

        bridge = new JackpotBridgeManager(
            IJackpot(address(jackpot)), IJackpotTicketNFT(address(nft)), IERC20(address(usdc)), "MegapotBridgeManager", "1.0.0"
        );

        usdc.transfer(buyer, 1_000 * USDC);
    }

    function ticket(uint8 a, uint8 b, uint8 c, uint8 d, uint8 e, uint8 bonus) internal pure returns (IJackpot.Ticket memory t) {
        t.normals = new uint8[](5);
        (t.normals[0], t.normals[1], t.normals[2], t.normals[3], t.normals[4]) = (a, b, c, d, e);
        t.bonusball = bonus;
    }

    function tickets(uint256 n) internal pure returns (IJackpot.Ticket[] memory ts) {
        ts = new IJackpot.Ticket[](n);
        for (uint256 i; i < n; i++) ts[i] = ticket(1, 2, 3, 4, uint8(5 + (i % 20)), 1);
    }

    function noRefs() internal pure returns (address[] memory r, uint256[] memory s) {
        r = new address[](0);
        s = new uint256[](0);
    }

    function bridgeBuy(address who, address recipient, IJackpot.Ticket[] memory ts, uint256 approveAmt)
        internal
        returns (uint256[] memory ids)
    {
        (address[] memory r, uint256[] memory s) = noRefs();
        vm.startPrank(who);
        usdc.approve(address(bridge), approveAmt);
        ids = bridge.buyTickets(ts, recipient, r, s, bytes32(0));
        vm.stopPrank();
    }

    /// Advance past drawingTime, run the jackpot and settle with chosen winning numbers.
    function settle(uint256 n1, uint256 n2, uint256 n3, uint256 n4, uint256 n5, uint256 bonus) internal {
        vm.warp(block.timestamp + 1 days + 1);
        uint256 fee = jackpot.getEntropyCallbackFee();
        vm.deal(address(this), fee);
        jackpot.runJackpot{ value: fee }();
        uint256[][] memory rn = new uint256[][](2);
        rn[0] = new uint256[](5);
        (rn[0][0], rn[0][1], rn[0][2], rn[0][3], rn[0][4]) = (n1, n2, n3, n4, n5);
        rn[1] = new uint256[](1);
        rn[1][0] = bonus;
        entropy.randomnessCallback(rn);
    }

    receive() external payable {}
}
