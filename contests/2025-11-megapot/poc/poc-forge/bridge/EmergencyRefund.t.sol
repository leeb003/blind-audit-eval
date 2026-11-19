// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import "./BridgeSetup.sol";

/// Lead: emergencyRefundTickets() deducts the *current global* referralFee (Jackpot.sol:591-592), not the fee
/// that was actually taken when the ticket was bought (Jackpot.sol _validateAndTrackReferrals uses referralFee at
/// purchase time). A referralFee change between purchase and emergency refund mis-sizes every referred refund.
contract EmergencyRefundTest is BridgeSetup {
    function _buyReferred(uint256 n) internal returns (uint256[] memory ids) {
        address[] memory r = new address[](1);
        r[0] = referrer;
        uint256[] memory s = new uint256[](1);
        s[0] = 1e18;
        vm.startPrank(buyer);
        usdc.approve(address(jackpot), type(uint256).max);
        ids = jackpot.buyTickets(tickets(n), buyer, r, s, bytes32(0));
        vm.stopPrank();
    }

    /// referralFee lowered after purchase: refunds pay out referral money that already went to the referrer,
    /// so refunded users are paid from LP funds (user + referrer together get > ticket price).
    function test_referralFeeLowered_refundOverpaysFromLpFunds() public {
        uint256[] memory ids = _buyReferred(100); // 100 USDC, 6.5% = 6.5 USDC to referrer
        assertEq(jackpot.referralFees(referrer), 6.5e6);

        jackpot.setReferralFee(0);
        jackpot.enableEmergencyMode();

        uint256 before = usdc.balanceOf(buyer);
        vm.prank(buyer);
        jackpot.emergencyRefundTickets(ids);
        uint256 refunded = usdc.balanceOf(buyer) - before;

        assertEq(refunded, 100 * USDC, "full ticket price refunded");
        // referrer still claims its 6.5 USDC -> 106.5 USDC paid out for 100 USDC received
        vm.prank(referrer);
        jackpot.claimReferralFees();
        assertEq(refunded + 6.5e6, 106.5e6);
    }

    /// referralFee raised after purchase: refunded users lose money that was never paid to anyone.
    function test_referralFeeRaised_refundUnderpaysUser() public {
        uint256[] memory ids = _buyReferred(100);
        jackpot.setReferralFee(0.5e18); // 50%
        jackpot.enableEmergencyMode();

        uint256 before = usdc.balanceOf(buyer);
        vm.prank(buyer);
        jackpot.emergencyRefundTickets(ids);
        uint256 refunded = usdc.balanceOf(buyer) - before;

        // user paid 100, referrer got 6.5, user gets back only 50 -> 43.5 USDC stuck/forfeited
        assertEq(refunded, 50 * USDC);
    }
}
