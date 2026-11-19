// SPDX-License-Identifier: MIT
pragma solidity 0.8.13;
import "./CrossBase.t.sol";
import {HybrSwapper} from "../../contracts/swapper/HybrSwapper.sol";
import {ISwapper} from "../../contracts/interfaces/ISwapper.sol";

/// Leads disproved by test.
contract DismissedTest is CrossBase {
    /// L: fixedConversionRate = 100% -> penalty 0 -> receivePenaltyReward(0) might revert (deposit_for ZV). It doesn't.
    function test_dismiss_fullRateRedeemDoesNotRevert() public {
        vm.warp(1_700_000_000);
        vm.startPrank(alice);
        hybr.approve(address(gHybr), type(uint256).max);
        gHybr.deposit(100e18, alice); // gHYBR has a veNFT
        vm.stopPrank();
        rewardHybr.setFixedConversionRate(10000);
        vm.startPrank(bob);
        hybr.approve(address(rewardHybr), type(uint256).max);
        rewardHybr.depostionEmissionsToken(10e18);
        uint256 before = hybr.balanceOf(bob);
        rewardHybr.redeem(10e18, 0);
        vm.stopPrank();
        assertEq(hybr.balanceOf(bob) - before, 10e18);
    }

    /// L: HybrSwapper.swapToHYBR is permissionless - can a caller use it to move someone else's tokens? No:
    /// it only pulls from msg.sender and only calls whitelisted aggregators.
    function test_dismiss_swapperOnlyPullsFromCaller() public {
        HybrSwapper sw = new HybrSwapper(address(hybr));
        usdx.transfer(alice, 100e18);
        vm.prank(alice);
        usdx.approve(address(sw), type(uint256).max); // alice approved the swapper
        // bob tries to route alice's approval through a non-whitelisted "aggregator" = the token itself
        ISwapper.SwapParams memory p = ISwapper.SwapParams({
            tokenIn: address(usdx), amountIn: 0, aggregator: address(usdx),
            callData: abi.encodeWithSignature("transferFrom(address,address,uint256)", alice, bob, 100e18), minAmountOut: 0
        });
        vm.prank(bob);
        vm.expectRevert();
        sw.swapToHYBR(p);
        assertEq(usdx.balanceOf(bob), 0);
    }

    /// L: gHYBR.withdraw -> safeTransferFrom(user) gives the user an onERC721Received callback mid-withdraw.
    /// Re-entering deposit/withdraw is blocked by nonReentrant; state (shares burned, veTokenId updated) is final
    /// before the callback.
    function test_dismiss_withdrawCallbackReentrancyBlocked() public {
        vm.warp(1_700_000_000);
        votingEscrow.toggleSplit(address(gHybr), true);
        gHybr.setTeam(makeAddr("team"));
        Reenterer r = new Reenterer(address(gHybr));
        hybr.transfer(address(r), 1_000e18);
        r.depositAll();
        vm.startPrank(alice);
        hybr.approve(address(gHybr), type(uint256).max);
        gHybr.deposit(1_000e18, alice);
        vm.stopPrank();
        warpToNextEpoch(gHybr.head_not_withdraw_time() + 1);
        r.withdrawHalf();
        assertTrue(r.reentryFailed());
    }
}

interface IGH {
    function deposit(uint256, address) external;
    function withdraw(uint256) external returns (uint256);
    function balanceOf(address) external view returns (uint256);
    function HYBR() external view returns (address);
}

contract Reenterer {
    IGH g; bool public reentryFailed;
    constructor(address _g) { g = IGH(_g); }
    function depositAll() external {
        (bool ok,) = g.HYBR().call(abi.encodeWithSignature("approve(address,uint256)", address(g), type(uint256).max));
        require(ok);
        g.deposit(1_000e18, address(this));
    }
    function withdrawHalf() external { g.withdraw(g.balanceOf(address(this)) / 2); }
    function onERC721Received(address, address, uint256, bytes calldata) external returns (bytes4) {
        try g.withdraw(1) { } catch { reentryFailed = true; }
        return this.onERC721Received.selector;
    }
}
