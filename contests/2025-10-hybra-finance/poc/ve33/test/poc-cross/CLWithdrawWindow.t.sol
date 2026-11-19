// SPDX-License-Identifier: MIT
pragma solidity 0.8.13;
import "./XCLBase.t.sol";
import {HybraTimeLibrary} from "../../contracts/libraries/HybraTimeLibrary.sol";

/// Impact extension of PokeWindowDoS: GaugeCL.withdraw() force-claims rewards through RewardHYBR.
/// While gHYBR's veNFT is voted, withdrawing a staked CL position in the no-voting window reverts for
/// redeemType 0 (HYBR) and 2 (gHYBR); the only way out is redeemType 1 = a forced 2-year veHYBR lock.
contract CLWithdrawWindowTest is XCLBase {
    function test_clWithdrawBlockedUnlessForcedMaxLock() public {
        vm.warp(1_700_000_000);
        // gHYBR gets a veNFT and votes for the CL pool
        hybr.approve(address(gHybr), type(uint256).max);
        gHybr.deposit(1_000e18, address(this));
        vm.warp(HybraTimeLibrary.epochNext(block.timestamp) + 301);
        address[] memory pools = new address[](1); pools[0] = pool;
        uint256[] memory w = new uint256[](1); w[0] = 1;
        gHybr.vote(pools, w);

        uint256 id = mintPosition(lpUser, -1000, 1000, 1_000e18);
        stake(lpUser, id);
        fundEmissions(100e18);
        vm.warp(block.timestamp + 600);

        vm.warp(HybraTimeLibrary.epochNext(block.timestamp) + 10); // no-voting window of next epoch
        vm.prank(lpUser);
        vm.expectRevert(bytes("DW"));
        gauge.withdraw(id, 0);
        vm.prank(lpUser);
        vm.expectRevert(bytes("DW"));
        gauge.withdraw(id, 2);

        // only escape: take rewards as a max-duration lock
        vm.prank(lpUser);
        gauge.withdraw(id, 1);
        assertEq(nfpm.ownerOf(id), lpUser);
    }
}
