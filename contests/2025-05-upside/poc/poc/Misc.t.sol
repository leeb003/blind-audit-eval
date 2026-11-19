// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.24;

import "./Base.t.sol";

contract MiscTest is BaseTest {
    /// Swaps stay open after withdrawLiquidity(); a buy then pays USDC (plus fee) for 0 MetaCoin.
    function test_buyAfterWithdrawReturnsNothing() public {
        useStub();
        address coin = tokenize("https://x.com/a");
        vm.warp(block.timestamp + 2 hours);
        buy(alice, coin, 1_000e6);

        vm.startPrank(owner);
        address[] memory coins = new address[](1);
        coins[0] = coin;
        protocol.withdrawLiquidity(coins); // starts timer
        vm.warp(block.timestamp + 14 days);
        protocol.withdrawLiquidity(coins);
        vm.stopPrank();

        uint256 before = usdc.balanceOf(bob);
        uint256 out = buy(bob, coin, 500e6);
        assertEq(out, 0);
        assertEq(before - usdc.balanceOf(bob), 500e6);

        // and the owner can sweep bob's USDC again immediately: the timer never resets
        uint256 ownerBefore = usdc.balanceOf(owner);
        vm.prank(owner);
        protocol.withdrawLiquidity(coins);
        assertGt(usdc.balanceOf(owner) - ownerBefore, 490e6);
    }

    /// "Tokenization of a URL can only happen once" only holds for the exact string.
    function test_sameUrlTokenizedTwice() public {
        useStub();
        address a = tokenize("https://x.com/user/status/1");
        address b = tokenize("https://x.com/user/status/1/");
        address c = tokenize("HTTPS://X.COM/user/status/1");
        address d = tokenize("https://twitter.com/user/status/1");
        assertTrue(a != b && b != c && c != d);
    }

    /// Before setFeeInfo() is called, swapFeeDecayInterval == 0 and every swap divides by zero.
    function test_swapRevertsBeforeFeeInfoSet() public {
        UpsideProtocol p = new UpsideProtocol(owner);
        UpsideStakingStub stub = new UpsideStakingStub(owner);
        vm.startPrank(owner);
        p.init(address(usdc));
        p.setStakingContractAddress(address(stub));
        vm.stopPrank();
        address coin = p.tokenize("u", address(0));
        vm.startPrank(alice);
        usdc.approve(address(p), 1e6);
        vm.expectRevert(stdError.divisionError);
        p.swap(coin, true, 1e6, 0, alice);
        vm.stopPrank();
    }

    /// Custom transferFrom decrements even an infinite allowance (OZ's standard doesn't).
    function test_infiniteAllowanceDecrements() public {
        useStub();
        address coin = tokenize("https://x.com/a");
        vm.warp(block.timestamp + 2 hours);
        uint256 bought = buy(alice, coin, 100e6);
        vm.prank(alice);
        IERC20(coin).approve(address(protocol), type(uint256).max);
        vm.prank(alice);
        protocol.swap(coin, false, bought / 2, 0, alice);
        assertLt(IERC20(coin).allowance(alice, address(protocol)), type(uint256).max);
    }
}
