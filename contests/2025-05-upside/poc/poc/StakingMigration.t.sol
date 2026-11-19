// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.24;

import "./Base.t.sol";

/// Lead: changing stakingContractAddress breaks every MetaCoin created before the change.
contract StakingMigrationTest is BaseTest {
    /// Stub -> real staking: coins tokenized under the stub can no longer be sold.
    function test_coinsFromBeforeMigrationCannotBeSold() public {
        useStub();
        address oldCoin = tokenize("https://x.com/old");
        vm.warp(block.timestamp + 2 hours); // let the buy fee decay to its floor
        uint256 bought = buy(alice, oldCoin, 1_000e6);

        // sells work under the stub
        sell(alice, oldCoin, bought / 10);

        // owner enables real staking
        UpsideStaking staking = useStaking();
        address newCoin = tokenize("https://x.com/new");
        assertTrue(staking.whitelistedStakingTokens(newCoin));
        assertFalse(staking.whitelistedStakingTokens(oldCoin));

        // every sell of the old coin now reverts inside distributeRewards()
        uint256 rest = IERC20(oldCoin).balanceOf(alice);
        vm.startPrank(alice);
        IERC20(oldCoin).approve(address(protocol), rest);
        vm.expectRevert(UpsideStaking.TokenNotWhitelisted.selector);
        protocol.swap(oldCoin, false, rest, 0, alice);
        vm.stopPrank();

        // the protocol owner has no way to fix it: UpsideProtocol exposes no call to
        // whitelistStakingToken(), and only the protocol (staking's owner) may call it
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, owner));
        staking.whitelistStakingToken(oldCoin);

        // USDC backing the old coin is stuck: alice's ~900 USDC position is unsellable
        (, , uint256 liqReserves, , ) = protocol.metaCoinInfoMap(oldCoin);
        assertGt(liqReserves - protocol.INITIAL_LIQUIDITY_RESERVES(), 800e6);
    }

    /// Staking v1 -> v2: users staked in v1 can't unstake or claim, since v1 lost its transfer whitelist.
    function test_stakersInOldContractAreStuck() public {
        UpsideStaking v1 = useStaking();
        address coin = tokenize("https://x.com/a");
        vm.warp(block.timestamp + 2 hours);
        uint256 bought = buy(alice, coin, 1_000e6);

        vm.startPrank(alice);
        IERC20(coin).approve(address(v1), bought);
        v1.stake(coin, bought);
        vm.stopPrank();

        useStaking(); // v2

        vm.prank(alice);
        vm.expectRevert(UpsideMetaCoin.NonTransferable.selector);
        v1.unstake(coin, bought);
    }
}

/// Severity check: is there an owner-side workaround? (If yes, judges may treat this as admin error.)
contract StakingMigrationWorkaroundTest is BaseTest {
    function test_workaround_deployAsEoaWhitelistThenHandOver() public {
        useStub();
        address oldCoin = tokenize("https://x.com/old");
        vm.warp(block.timestamp + 2 hours);
        uint256 bought = buy(alice, oldCoin, 1_000e6);

        // owner deploys staking owned by themselves, whitelists old coins, then hands ownership to the protocol
        vm.startPrank(owner);
        UpsideStaking staking = new UpsideStaking(owner, feeSink);
        staking.whitelistStakingToken(oldCoin);
        staking.transferOwnership(address(protocol));
        protocol.setStakingContractAddress(address(staking));
        vm.stopPrank();

        sell(alice, oldCoin, bought); // works
        tokenize("https://x.com/new"); // still works
    }
}
