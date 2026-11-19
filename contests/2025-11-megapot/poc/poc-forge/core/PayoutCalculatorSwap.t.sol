// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import "./CoreBase.t.sol";

/// Lead: claimWinnings reads tier payouts for PAST drawings from the *current* payoutCalculator.
/// Replacing the calculator (e.g. to change payout rules going forward) zeroes all unclaimed winnings,
/// and the claim burns the ticket, so the winner loses them permanently.
contract PayoutCalculatorSwapTest is CoreBase {
    function test_swappingCalculatorWipesUnclaimedWinnings() public {
        // alice buys a ticket matching the bonusball only (tier 1 has a guaranteed minimum payout)
        uint256 id = buyOne(alice, 0, false); // normals 1,2,3,4,5 bonus 1
        settle(defaultNormals(), 1);          // winning 26..30, bonus 1
        uint256 owed = calc.getTierPayout(1, 1);
        assertGt(owed, 0, "alice won something");

        // owner deploys a new calculator for future drawings
        bool[12] memory minTiers = [false, true, false, true, true, true, true, true, true, true, true, true];
        uint256[12] memory weights = [
            uint256(0), 0.17 ether, 0, 0.13 ether, 0.12 ether, 0.05 ether,
            0.05 ether, 0.02 ether, 0.02 ether, 0.01 ether, 0.04 ether, 0.39 ether
        ];
        vm.startPrank(owner);
        GuaranteedMinimumPayoutCalculator calc2 =
            new GuaranteedMinimumPayoutCalculator(IJackpot(address(jackpot)), 1e6, 0.2 ether, minTiers, weights);
        jackpot.setPayoutCalculator(IPayoutCalculator(address(calc2)));
        vm.stopPrank();

        uint256 before = usdc.balanceOf(alice);
        uint256[] memory ids = new uint256[](1);
        ids[0] = id;
        vm.prank(alice);
        jackpot.claimWinnings(ids);

        assertEq(usdc.balanceOf(alice) - before, 0, "alice receives nothing");
        vm.expectRevert(); // ticket burned, can't retry even if owner switches back
        nft.ownerOf(id);
    }
}
