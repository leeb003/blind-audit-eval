// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import "./CoreBase.t.sol";

/// Lead: scaledEntropyCallback has no noEmergencyMode guard. If the drawing is stuck waiting on entropy,
/// the owner enables emergency mode and users refund their tickets, a late callback still settles the drawing
/// and credits the refunded ticket revenue (lpEarnings) to LPs -> LP accounting exceeds real USDC.
contract EmergencyCallbackTest is CoreBase {
    address lp2 = makeAddr("lp2");

    function test_lateCallbackAfterRefundsCreatesPhantomLpValue() public {
        // second LP so we can show who ends up short
        vm.prank(owner);
        usdc.transfer(lp2, 1_000_000e6);
        vm.startPrank(lp2);
        usdc.approve(address(jackpot), type(uint256).max);
        jackpot.lpDeposit(1_000_000e6);
        vm.stopPrank();
        // settle drawing 1 with no tickets so lp2's deposit becomes active
        settle(defaultNormals(), 1);

        // drawing 2: alice buys 1,000 tickets (1,000 USDC)
        uint256[] memory ids = _buyMany(alice, 1_000);

        // drawing is run, entropy callback is delayed ("jackpot gets stuck")
        vm.warp(jackpot.getDrawingState(2).drawingTime + 1);
        jackpot.runJackpot{value: 1 ether}();

        // owner enables emergency mode; alice refunds all tickets (1,000 USDC back)
        vm.prank(owner);
        jackpot.enableEmergencyMode();
        vm.prank(alice);
        jackpot.emergencyRefundTickets(ids);
        assertEq(usdc.balanceOf(alice), 1_000_000e6);

        // the late callback still goes through while in emergency mode
        uint256[][] memory rn = new uint256[][](2);
        rn[0] = defaultNormals();
        rn[1] = new uint256[](1);
        rn[1][0] = 5; // none of the refunded tickets win, isolating the phantom revenue
        entropy.randomnessCallback(rn);
        assertEq(jackpot.currentDrawingId(), 3, "drawing settled despite emergency + refunds");

        // LP value now includes the refunded 1,000 USDC ticket revenue that no longer exists
        uint256 lpClaims = lpManager.getLPDrawingState(3).lpPoolTotal;
        uint256 owedWinnings = 0; // alice's tickets were burned; nothing else outstanding
        uint256 bal = usdc.balanceOf(address(jackpot));
        emit log_named_decimal_uint("USDC held by jackpot", bal, 6);
        emit log_named_decimal_uint("LP pool total claimed", lpClaims, 6);
        assertGt(lpClaims + owedWinnings, bal, "LPs are owed more than the contract holds");

        // both LPs emergency-withdraw: the first gets paid in full, the last cannot be paid
        vm.prank(lp);
        jackpot.emergencyWithdrawLP();
        vm.prank(lp2);
        vm.expectRevert();
        jackpot.emergencyWithdrawLP();
    }

    function _buyMany(address who, uint256 n) internal returns (uint256[] memory ids) {
        ids = new uint256[](n);
        uint256 done;
        address[] memory none = new address[](0);
        uint256[] memory noneS = new uint256[](0);
        // unique combos from 1..25 with bonusball 1..5
        for (uint8 a = 1; a <= 21 && done < n; a++)
        for (uint8 b = a + 1; b <= 22 && done < n; b++)
        for (uint8 c = b + 1; c <= 23 && done < n; c++) {
            IJackpot.Ticket[] memory ts = new IJackpot.Ticket[](1);
            ts[0] = ticket(a, b, c, 24, 25, 1);
            ids[done++] = buy(who, ts, none, noneS)[0];
        }
        // top up with duplicates if needed
        while (done < n) {
            IJackpot.Ticket[] memory ts = new IJackpot.Ticket[](1);
            ts[0] = ticket(1, 2, 3, 24, 25, 2);
            ids[done++] = buy(who, ts, none, noneS)[0];
        }
    }
}
