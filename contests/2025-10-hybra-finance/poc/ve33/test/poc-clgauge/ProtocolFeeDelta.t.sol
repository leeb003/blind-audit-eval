// SPDX-License-Identifier: MIT
pragma solidity 0.8.13;

import "./CLGaugeBase.t.sol";

interface INFPMCollect {
    struct CollectParams { uint256 tokenId; address recipient; uint128 amount0Max; uint128 amount1Max; }
    function collect(CollectParams calldata params) external payable returns (uint256, uint256);
    struct DecreaseLiquidityParams { uint256 tokenId; uint128 liquidity; uint256 amount0Min; uint256 amount1Min; uint256 deadline; }
    function decreaseLiquidity(DecreaseLiquidityParams calldata params) external payable returns (uint256, uint256);
    function positions(uint256) external view returns (uint96, address, address, address, int24, int24, int24, uint128, uint256, uint256, uint128, uint128);
}

interface IFactoryProto {
    function collectProtocolFees(address pool) external returns (uint128, uint128);
    function getProtocolFee(address pool) external view returns (uint24);
    function getUnstakedFee(address pool) external view returns (uint24);
    function owner() external view returns (address);
    function createPool(address, address, int24, uint160) external returns (address);
    function setGaugeManager(address) external;
}

/// Hybra delta: protocol fee on unstaked fees when the pool's gauge is dead (or absent).
contract ProtocolFeeDeltaTest is CLGaugeBase {
    /// Kill the gauge, trade both ways, then every party withdraws everything: pool must stay solvent.
    function test_dismiss_protocolFeeAccountingSolventAfterGaugeKilled() public {
        uint256 idA = mintPosition(lpUser, -2000, 2000, 100_000e18);   // unstaked
        uint256 idB = mintPosition(lpUser2, -2000, 2000, 100_000e18);
        stake(lpUser2, idB);                                            // staked
        gaugeManager.killGauge(address(gauge));
        assertEq(IFactoryProto(clPoolFactory).getProtocolFee(pool), 250_000, "25% protocol fee on dead gauge");
        assertEq(IFactoryProto(clPoolFactory).getUnstakedFee(pool), 0);

        for (uint256 i; i < 10; i++) {
            swap(trader, token0, 5_000e18);
            swap(trader, token1, 5_000e18);
        }

        // protocol collects
        address fOwner = IFactoryProto(clPoolFactory).owner();
        vm.prank(fOwner);
        (uint128 p0, uint128 p1) = IFactoryProto(clPoolFactory).collectProtocolFees(pool);
        assertGt(uint256(p0) + p1, 0, "protocol fees accrued");

        // gauge fees swept to bribe (dead gauge can still claim)
        gauge.claimFees();

        // unstaked LP removes everything
        (,,,,,,, uint128 liqA,,,,) = INFPMCollect(address(nfpm)).positions(idA);
        vm.startPrank(lpUser);
        INFPMCollect(address(nfpm)).decreaseLiquidity(INFPMCollect.DecreaseLiquidityParams(idA, liqA, 0, 0, block.timestamp));
        INFPMCollect(address(nfpm)).collect(INFPMCollect.CollectParams(idA, lpUser, type(uint128).max, type(uint128).max));
        vm.stopPrank();

        // staked LP exits gauge then removes everything
        vm.prank(lpUser2);
        gauge.withdraw(idB, 0);
        (,,,,,,, uint128 liqB,,,,) = INFPMCollect(address(nfpm)).positions(idB);
        vm.startPrank(lpUser2);
        INFPMCollect(address(nfpm)).decreaseLiquidity(INFPMCollect.DecreaseLiquidityParams(idB, liqB, 0, 0, block.timestamp));
        INFPMCollect(address(nfpm)).collect(INFPMCollect.CollectParams(idB, lpUser2, type(uint128).max, type(uint128).max));
        vm.stopPrank();

        // leftover is dust only
        assertLt(IERC20(token0).balanceOf(pool), 1e6, "token0 dust only");
        assertLt(IERC20(token1).balanceOf(pool), 1e6, "token1 dust only");
    }

    /// QA: pools created before CLFactory.setGaugeManager keep gaugeManager == 0 and can never get a gauge.
    /// (Pool creation is permissionless.)
    function test_qa_poolCreatedBeforeGaugeManagerSetIsNeverGaugeable() public {
        address fOwner = IFactoryProto(clPoolFactory).owner();
        vm.prank(fOwner);
        IFactoryProto(clPoolFactory).setGaugeManager(address(0));
        TokenX y = new TokenX();
        tokenHandler.whitelistToken(address(y));
        address early = IFactoryProto(clPoolFactory).createPool(address(hybr), address(y), TS, uint160(1 << 96));
        vm.prank(fOwner);
        IFactoryProto(clPoolFactory).setGaugeManager(address(gaugeManager));
        vm.expectRevert();
        gaugeManager.createGauge(early, 1);
    }
}
