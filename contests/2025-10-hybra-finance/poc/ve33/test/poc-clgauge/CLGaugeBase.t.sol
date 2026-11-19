// SPDX-License-Identifier: MIT
pragma solidity 0.8.13;

import "forge-std/Test.sol";
import {C4PoCTestbed} from "../C4PoCTestbed.t.sol";
import {GaugeCL} from "../../contracts/CLGauge/GaugeCL.sol";
import {INonfungiblePositionManager} from "../../contracts/CLGauge/interface/INonfungiblePositionManager.sol";
import {ICLPool} from "../../contracts/CLGauge/interface/ICLPool.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract TokenX is ERC20 {
    constructor() ERC20("X", "X") { _mint(msg.sender, 1e30); }
}

interface ICLFactoryLite {
    function createPool(address tokenA, address tokenB, int24 tickSpacing, uint160 sqrtPriceX96) external returns (address);
    function setGaugeManager(address) external;
    function owner() external view returns (address);
}

interface ISwapRouterLite {
    struct ExactInputSingleParams {
        address tokenIn; address tokenOut; int24 tickSpacing; address recipient; uint256 deadline;
        uint256 amountIn; uint256 amountOutMinimum; uint160 sqrtPriceLimitX96;
    }
    function exactInputSingle(ExactInputSingleParams calldata params) external payable returns (uint256 amountOut);
}

/// Deploys a real CL pool (imported bytecode) + GaugeCL via GaugeManager, as production would.
abstract contract CLGaugeBase is C4PoCTestbed {
    TokenX tokenX;
    address pool;
    GaugeCL gauge;
    INonfungiblePositionManager nfpm;
    address token0;
    address token1;
    int24 constant TS = 100;

    address lpUser = makeAddr("lpUser");
    address lpUser2 = makeAddr("lpUser2");
    address attacker = makeAddr("attacker");
    address trader = makeAddr("trader");

    function setUp() public virtual override {
        super.setUp();
        nfpm = INonfungiblePositionManager(clNonfungiblePositionManager);
        // testbed helper computes `uint80(1) << 176` in 80-bit math (== 0), leaving _nextPoolId = 0;
        // set _nextId = 1, _nextPoolId = 1 as the NFPM constructor does
        vm.store(clNonfungiblePositionManager, bytes32(uint256(14)), bytes32(uint256(1) | (uint256(1) << 176)));
        tokenX = new TokenX();

        // testbed leaves BribeFactoryV3 uninitialized; do what the deploy script would
        bribeFactoryV3.initialize(address(voter), address(gaugeManager), address(permissionsRegistry), address(tokenHandler));
        if (!permissionsRegistry.hasRole("GOVERNANCE", deployer)) permissionsRegistry.setRoleFor(deployer, "GOVERNANCE");
        tokenHandler.whitelistToken(address(hybr));
        tokenHandler.whitelistToken(address(tokenX));
        tokenHandler.whitelistConnector(address(hybr));

        vm.prank(ICLFactoryLite(clPoolFactory).owner());
        ICLFactoryLite(clPoolFactory).setGaugeManager(address(gaugeManager));

        pool = ICLFactoryLite(clPoolFactory).createPool(address(hybr), address(tokenX), TS, uint160(1 << 96));
        (address g,,) = gaugeManager.createGauge(pool, 1);
        gauge = GaugeCL(g);
        (token0, token1) = address(hybr) < address(tokenX) ? (address(hybr), address(tokenX)) : (address(tokenX), address(hybr));

        // fund users
        address[4] memory us = [lpUser, lpUser2, attacker, trader];
        for (uint256 i; i < us.length; i++) {
            hybr.transfer(us[i], 10_000_000e18);
            tokenX.transfer(us[i], 10_000_000e18);
            vm.startPrank(us[i]);
            hybr.approve(address(nfpm), type(uint256).max);
            tokenX.approve(address(nfpm), type(uint256).max);
            hybr.approve(clSwapRouter, type(uint256).max);
            tokenX.approve(clSwapRouter, type(uint256).max);
            vm.stopPrank();
        }
    }

    function mintPosition(address who, int24 lower, int24 upper, uint256 amt) internal returns (uint256 tokenId) {
        vm.prank(who);
        (tokenId,,,) = nfpm.mint(INonfungiblePositionManager.MintParams({
            token0: token0, token1: token1, tickSpacing: TS, tickLower: lower, tickUpper: upper,
            amount0Desired: amt, amount1Desired: amt, amount0Min: 0, amount1Min: 0,
            recipient: who, deadline: block.timestamp, sqrtPriceX96: 0
        }));
    }

    function stake(address who, uint256 tokenId) internal {
        vm.startPrank(who);
        nfpm.approve(address(gauge), tokenId);
        gauge.deposit(tokenId);
        vm.stopPrank();
    }

    /// Emissions arrive exactly as GaugeManager.distribute would send them.
    function fundEmissions(uint256 amount) internal {
        hybr.transfer(address(gaugeManager), amount);
        vm.prank(address(gaugeManager));
        gauge.notifyRewardAmount(address(hybr), amount);
    }

    function swap(address who, address tokenIn, uint256 amountIn) internal returns (uint256) {
        address tokenOut = tokenIn == token0 ? token1 : token0;
        vm.prank(who);
        return ISwapRouterLite(clSwapRouter).exactInputSingle(ISwapRouterLite.ExactInputSingleParams({
            tokenIn: tokenIn, tokenOut: tokenOut, tickSpacing: TS, recipient: who, deadline: block.timestamp,
            amountIn: amountIn, amountOutMinimum: 0, sqrtPriceLimitX96: 0
        }));
    }
}
