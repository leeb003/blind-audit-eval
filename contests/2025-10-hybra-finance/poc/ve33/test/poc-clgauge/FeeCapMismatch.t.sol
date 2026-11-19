// SPDX-License-Identifier: MIT
pragma solidity 0.8.13;

import "./CLGaugeBase.t.sol";

interface IFeeModuleLite {
    function setCustomFee(address pool, uint24 fee) external;
    function setFeeCap(address pool, uint24 feeCap) external;
    function setScalingFactor(address pool, uint64 scalingFactor) external;
    function getFee(address pool) external view returns (uint24);
}

interface IPoolFeeLite {
    function fee() external view returns (uint24);
}

interface IFactoryFeeLite {
    function tickSpacingToFee(int24) external view returns (uint24);
}

/// Lead: Hybra raised DynamicSwapFeeModule MAX_BASE_FEE / MAX_FEE_CAP to 50% ("launch anti-MEV protection"),
/// but CLFactory.getSwapFee still discards any module fee > 10% and falls back to tickSpacingToFee.
/// A high launch fee therefore silently becomes the tiny base fee.
contract FeeCapMismatchTest is CLGaugeBase {
    function test_launchFeeAbove10PercentFallsBackToBaseFee() public {
        IFeeModuleLite m = IFeeModuleLite(clSwapFeeModule);
        vm.startPrank(feeManager);
        m.setFeeCap(pool, 500_000);        // allowed by module (MAX_FEE_CAP = 50%)
        m.setScalingFactor(pool, 1);       // use the per-pool config
        m.setCustomFee(pool, 300_000);     // 30% launch anti-MEV fee (MAX_BASE_FEE = 50%)
        vm.stopPrank();

        assertGe(m.getFee(pool), 300_000, "module computes >= 30%");
        uint24 baseFee = IFactoryFeeLite(clPoolFactory).tickSpacingToFee(TS);
        assertEq(IPoolFeeLite(pool).fee(), baseFee, "pool actually charges the tick-spacing base fee");
        emit log_named_uint("intended fee (pips)", m.getFee(pool));
        emit log_named_uint("charged fee  (pips)", IPoolFeeLite(pool).fee());

        // a sniper swapping at launch pays the base fee instead of 30%
        mintPosition(lpUser, -10000, 10000, 1_000_000e18);
        uint256 out = swap(trader, token0, 1000e18);
        assertGt(out, 990e18, "trader lost < 1% instead of ~30%");
    }

    /// Control: at exactly 10% the module fee is honoured - so the cliff is at 10%, not a general failure.
    function test_control_10PercentHonoured() public {
        IFeeModuleLite m = IFeeModuleLite(clSwapFeeModule);
        vm.startPrank(feeManager);
        m.setFeeCap(pool, 500_000);
        m.setScalingFactor(pool, 1);
        m.setCustomFee(pool, 100_000);
        vm.stopPrank();
        assertEq(IPoolFeeLite(pool).fee(), 100_000);
    }
}
