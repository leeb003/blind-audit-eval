// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import "./CoreBase.t.sol";

/// Lead: referralFee is read live (not snapshotted per drawing), and emergencyRefundTickets
/// refunds referral tickets using the *current* referralFee instead of the fee actually charged.
contract ReferralFeeTest is CoreBase {
    function test_sanity_buyAndSettle() public {
        buyOne(alice, 0, false);
        settle(defaultNormals(), 1);
        assertEq(jackpot.currentDrawingId(), 2);
    }

    /// Owner lowers referralFee mid-drawing (e.g. a promo for the next drawing). Emergency refunds then
    /// pay referral-ticket holders more than the contract kept from them, paid out of other users' money.
    function test_emergencyRefundUsesLiveReferralFee() public {
        // 100 tickets bought with a referrer at 6.5%: jackpot keeps 93.5 USDC, referrer is owed 6.5 USDC
        uint256[] memory ids = new uint256[](100);
        for (uint256 i; i < 100; i++) ids[i] = buyOne(alice, uint8(i), true);
        assertEq(jackpot.referralFees(ref1), 6.5e6);

        // owner changes the referral fee (no per-drawing snapshot exists for it)
        vm.prank(owner);
        jackpot.setReferralFee(0);

        // jackpot gets stuck -> emergency mode
        vm.prank(owner);
        jackpot.enableEmergencyMode();

        uint256 before = usdc.balanceOf(alice);
        vm.prank(alice);
        jackpot.emergencyRefundTickets(ids);
        uint256 refunded = usdc.balanceOf(alice) - before;

        // alice gets the full 100 USDC back, although only 93.5 stayed in the contract;
        // the referrer can still claim the 6.5 USDC -> 6.5 USDC comes out of LP funds
        assertEq(refunded, 100e6);
        vm.prank(ref1);
        jackpot.claimReferralFees();
        assertEq(usdc.balanceOf(ref1), 6.5e6);
    }

    /// Opposite direction: owner raises the fee mid-drawing -> referral-ticket holders are under-refunded
    /// and the difference is stranded in the contract (not credited to anyone).
    function test_emergencyRefundUnderpaysAfterFeeIncrease() public {
        uint256[] memory ids = new uint256[](10);
        for (uint256 i; i < 10; i++) ids[i] = buyOne(alice, uint8(i), true);

        vm.startPrank(owner);
        jackpot.setReferralFee(0.5 ether);
        jackpot.enableEmergencyMode();
        vm.stopPrank();

        uint256 before = usdc.balanceOf(alice);
        vm.prank(alice);
        jackpot.emergencyRefundTickets(ids);
        // paid 10 USDC, 0.65 went to referrer, but only 5 USDC refunded (should be 9.35)
        assertEq(usdc.balanceOf(alice) - before, 5e6);
    }

    /// referralFee also changes the price split for tickets bought later in the SAME drawing,
    /// contradicting "Admin parameter changes apply to future drawings".
    function test_referralFeeChangeAppliesMidDrawing() public {
        buyOne(alice, 0, true);
        assertEq(jackpot.referralFees(ref1), 0.065e6);
        vm.prank(owner);
        jackpot.setReferralFee(0.2 ether);
        buyOne(alice, 1, true);
        assertEq(jackpot.referralFees(ref1), 0.065e6 + 0.2e6);
    }
}
