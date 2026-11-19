// SPDX-License-Identifier: MIT
pragma solidity 0.8.13;

import "./CLGaugeBase.t.sol";

interface ICLPoolRewardsLite {
    function rollover() external view returns (uint256);
    function rewardReserve() external view returns (uint256);
    function stakedLiquidity() external view returns (uint128);
    function gaugeFees() external view returns (uint128, uint128);
    function slot0() external view returns (uint160, int24, uint16, uint16, uint16, bool);
}

interface INFPMIncrease {
    struct IncreaseLiquidityParams {
        uint256 tokenId; uint256 amount0Desired; uint256 amount1Desired; uint256 amount0Min; uint256 amount1Min; uint256 deadline;
    }
    function increaseLiquidity(IncreaseLiquidityParams calldata params) external payable returns (uint128, uint256, uint256);
}

interface IGaugeManagerClaim {
    function claimRewards(address _gauge, uint256[] memory _nftIds, uint8 _redeemType) external;
}

/// Sponsor concern #1: do CL gauge emissions follow the staked position's ACTIVE range?
/// These are disproof tests for leads that turned out fine.
contract RewardRangeTest is CLGaugeBase {
    function _swapToLimit(address who, address tokenIn, uint256 amountIn, uint160 limit) internal {
        address tokenOut = tokenIn == token0 ? token1 : token0;
        vm.prank(who);
        ISwapRouterLite(clSwapRouter).exactInputSingle(ISwapRouterLite.ExactInputSingleParams({
            tokenIn: tokenIn, tokenOut: tokenOut, tickSpacing: TS, recipient: who, deadline: block.timestamp,
            amountIn: amountIn, amountOutMinimum: 0, sqrtPriceLimitX96: limit
        }));
    }

    function _payout(address who, uint256 id) internal returns (uint256 got) {
        uint256 before = hybr.balanceOf(who);
        vm.prank(who);
        gauge.withdraw(id, 0);
        got = hybr.balanceOf(who) - before;
    }

    function test_dismiss_outOfRangeEarnsNothing_inRangeEarnsAll() public {
        uint256 inR = mintPosition(lpUser, -1000, 1000, 1000e18);
        uint256 outR = mintPosition(lpUser2, 2000, 3000, 1000e18); // above current tick 0 -> out of range
        stake(lpUser, inR);
        stake(lpUser2, outR);
        fundEmissions(700_000e18);
        vm.warp(block.timestamp + 1 days);
        uint256 a = _payout(lpUser, inR);
        uint256 b = _payout(lpUser2, outR);
        emit log_named_decimal_uint("in-range payout", a, 18);
        emit log_named_decimal_uint("out-of-range payout", b, 18);
        assertGt(a, 0);
        assertEq(b, 0, "out of range earns nothing");
    }

    function test_dismiss_rewardsFollowPriceIntoRange_noOverpay() public {
        uint256 inR = mintPosition(lpUser, -1000, 1000, 1000e18);
        uint256 upR = mintPosition(lpUser2, 1000, 3000, 1000e18);
        stake(lpUser, inR);
        stake(lpUser2, upR);
        fundEmissions(700_000e18);
        uint256 t0 = block.timestamp;
        uint256 periodEnd = (t0 / 1800 + 1) * 1800; // HybraTimeLibrary.WEEK = 1800s in this codebase
        uint256 half = (periodEnd - t0) / 2;
        vm.warp(t0 + half);
        // push price up into lpUser2's range (token1 -> token0 direction raises tick)
        _swapToLimit(trader, token1, 3000e18, uint160(87560223330309670419052669888)); // sqrtPrice at tick 2000
        (, int24 tick,,,,) = ICLPoolRewardsLite(pool).slot0();
        emit log_named_int("tick after swap", tick);
        assertGe(tick, 1000, "price moved into upper range");
        assertLt(tick, 3000, "still inside lpUser2 range");
        vm.warp(periodEnd + 1);
        uint256 a = _payout(lpUser, inR);
        uint256 b = _payout(lpUser2, upR);
        emit log_named_decimal_uint("first-half LP", a, 18);
        emit log_named_decimal_uint("second-half LP", b, 18);
        assertGt(a, 0);
        assertGt(b, 0);
        // paid out (after 80% rHYBR conversion) never exceeds emissions
        assertLe(a + b, 700_000e18 * 8 / 10 + 1e18, "no over-distribution");
    }

    function test_dismiss_cannotIncreaseLiquidityOfStakedNft() public {
        uint256 id = mintPosition(lpUser, -1000, 1000, 1000e18);
        stake(lpUser, id);
        vm.prank(lpUser);
        vm.expectRevert(bytes("NG"));
        INFPMIncrease(address(nfpm)).increaseLiquidity(INFPMIncrease.IncreaseLiquidityParams(id, 1e18, 1e18, 0, 0, block.timestamp));
    }

    function test_dismiss_thirdPartyCannotPickVictimRedeemType() public {
        uint256 id = mintPosition(lpUser, -1000, 1000, 1000e18);
        stake(lpUser, id);
        fundEmissions(700_000e18);
        vm.warp(block.timestamp + 1 days);
        uint256[] memory ids = new uint256[](1);
        ids[0] = id;
        vm.prank(attacker);
        vm.expectRevert(bytes("NA"));
        IGaugeManagerClaim(address(gaugeManager)).claimRewards(address(gauge), ids, 0);
    }

    function test_dismiss_protocolFeeAndUnstakedFeeExclusive_gaugeGetsUnstakedCut() public {
        mintPosition(lpUser, -1000, 1000, 1000e18); // unstaked only
        (uint128 g0Before,) = ICLPoolRewardsLite(pool).gaugeFees();
        swap(trader, token0, 100e18);
        (uint128 g0After,) = ICLPoolRewardsLite(pool).gaugeFees();
        assertGt(g0After, g0Before, "live gauge receives unstaked-fee cut");
    }

    /// QA: in emergency mode GaugeCL has no exit path - staked NFTs are frozen until the owner stops emergency.
    function test_qa_emergencyFreezesStakedNfts() public {
        uint256 id = mintPosition(lpUser, -1000, 1000, 1000e18);
        stake(lpUser, id);
        address[] memory gs = new address[](1);
        gs[0] = address(gauge);
        vm.prank(permissionsRegistry.emergencyCouncil());
        gaugeFactoryCL.activateEmergencyMode(gs);
        vm.prank(lpUser);
        vm.expectRevert(bytes("emergency"));
        gauge.withdraw(id, 0);
    }
}
