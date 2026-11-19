// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import "./LPBase.t.sol";
import { IERC20Errors } from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";

contract GlobalParamsTest is LPBase {
    /// setPayoutCalculator(): claimWinnings reads tier payouts for PAST drawings from the CURRENT calculator.
    /// Unclaimed winners of prior drawings get 0 (ticket burned) though the LP pool already paid for them.
    function test_swapPayoutCalculator_zeroesPriorWinnings() public {
        uint256[] memory ids = _buy(_ticket(1, 2, 3, 4, 5, 1), 1, false);
        _draw([uint256(1), 2, 3, 4, 5], 1); // buyer hits the jackpot tier (5 + bonus)

        uint256 owed = calc.getTierPayout(1, 11);
        assertGt(owed, 100_000 * U, "jackpot tier payout reserved");
        // LP pool was debited: next drawing's LP value is far below the 1M deposited
        assertLt(lpManager.getLPDrawingState(2).lpPoolTotal, 1_000_000 * U - owed + 10 * U);

        // owner upgrades the payout calculator (same params) between drawings
        GuaranteedMinimumPayoutCalculator calc2 = _newCalc();
        vm.prank(owner);
        jackpot.setPayoutCalculator(IPayoutCalculator(address(calc2)));

        uint256 before = usdc.balanceOf(buyer);
        vm.prank(buyer);
        jackpot.claimWinnings(ids);
        assertEq(usdc.balanceOf(buyer) - before, 0, "winner paid nothing");
        // ticket is gone, the reserved ~owed USDC is now stranded in the contract forever
        vm.expectRevert();
        nft.ownerOf(ids[0]);
    }

    /// Same swap mid-drawing: the new calculator has no tier info for the running drawing,
    /// so settlement computes 0 user winnings and the LPs keep everything.
    function test_swapPayoutCalculator_midDrawingWinnersGetNothing() public {
        GuaranteedMinimumPayoutCalculator calc2 = _newCalc();
        uint256[] memory ids = _buy(_ticket(1, 2, 3, 4, 5, 1), 1, false);
        vm.prank(owner);
        jackpot.setPayoutCalculator(IPayoutCalculator(address(calc2)));
        _draw([uint256(1), 2, 3, 4, 5], 1);

        assertEq(calc2.getTierPayout(1, 11), 0);
        uint256 before = usdc.balanceOf(buyer);
        vm.prank(buyer);
        jackpot.claimWinnings(ids);
        assertEq(usdc.balanceOf(buyer) - before, 0, "jackpot winner paid nothing");
    }

    /// emergencyRefundTickets() prices referral-ticket refunds with the GLOBAL referralFee,
    /// not the fee actually charged at purchase. Lowering it mid-drawing over-refunds out of LP funds.
    function test_referralFeeChange_emergencyRefundDrainsLPs() public {
        uint256[] memory ids = _buy(_ticket(1, 2, 3, 4, 5, 1), 1000, true); // 1000 USDC, 65 to referrer
        vm.prank(referrer);
        jackpot.claimReferralFees();

        vm.startPrank(owner);
        jackpot.setReferralFee(0);
        jackpot.enableEmergencyMode();
        vm.stopPrank();

        uint256 before = usdc.balanceOf(buyer);
        vm.prank(buyer);
        jackpot.emergencyRefundTickets(ids);
        assertEq(usdc.balanceOf(buyer) - before, 1000 * U, "full refund incl. referral cut already paid out");

        // the LP can no longer get their 1M back: contract is 65 USDC short
        assertEq(usdc.balanceOf(address(jackpot)), 1_000_000 * U - 65 * U);
        vm.prank(lp);
        vm.expectRevert();
        jackpot.emergencyWithdrawLP();
    }
}
