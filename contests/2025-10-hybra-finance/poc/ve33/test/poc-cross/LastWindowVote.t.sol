// SPDX-License-Identifier: MIT
pragma solidity 0.8.13;
import "./CrossBase.t.sol";

/// Fork delta: Blackhole's _vote reverted after epochVoteEnd for non-whitelisted NFTs (anti vote-sniping window).
/// Hybra removed that check, so any veNFT can vote/switch in the last seconds of the epoch.
contract LastWindowVoteTest is CrossBase {
    function test_anyNftCanVoteInFinalSeconds() public {
        vm.warp(1_700_000_000);
        vm.startPrank(alice);
        hybr.approve(address(votingEscrow), type(uint256).max);
        uint256 id = votingEscrow.create_lock(1_000e18, 365 days);
        vm.stopPrank();
        assertFalse(tokenHandler.isWhitelistedNFT(id));

        vm.warp(HybraTimeLibrary.epochNext(block.timestamp) - 1); // last second, after epochVoteEnd
        assertGe(block.timestamp, HybraTimeLibrary.epochVoteEnd(block.timestamp));
        address[] memory pools = new address[](1); pools[0] = pair;
        uint256[] memory w = new uint256[](1); w[0] = 1;
        vm.prank(alice);
        voter.vote(id, pools, w); // Blackhole: revert("AVM_W")-style restriction; Hybra: succeeds
        assertGt(voter.weights(pair), 0);
    }
}
