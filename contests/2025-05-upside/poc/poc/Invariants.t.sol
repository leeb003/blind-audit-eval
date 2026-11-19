// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.24;

import "./Base.t.sol";

/// Drives random buys/sells/claims across two coins and several traders.
contract Handler is Test {
    UpsideProtocol protocol;
    USDCMock usdc;
    address[] public coins;
    address[] traders;
    address deployer;

    constructor(UpsideProtocol _p, USDCMock _u, address[] memory _coins, address _deployer) {
        protocol = _p;
        usdc = _u;
        coins = _coins;
        deployer = _deployer;
        for (uint256 i; i < 4; i++) {
            address t = makeAddr(string(abi.encodePacked("trader", i)));
            traders.push(t);
            usdc.mint(t, 10_000_000e6);
        }
    }

    function buy(uint256 who, uint256 coin, uint256 amount, uint256 dt) external {
        address t = traders[who % traders.length];
        address c = coins[coin % coins.length];
        amount = bound(amount, 1, 1_000_000e6);
        vm.warp(block.timestamp + bound(dt, 0, 1 hours));
        vm.startPrank(t);
        usdc.approve(address(protocol), amount);
        protocol.swap(c, true, amount, 0, t);
        vm.stopPrank();
    }

    function sell(uint256 who, uint256 coin, uint256 amount) external {
        address t = traders[who % traders.length];
        address c = coins[coin % coins.length];
        uint256 bal = IERC20(c).balanceOf(t);
        if (bal == 0) return;
        amount = bound(amount, 1, bal);
        vm.startPrank(t);
        IERC20(c).approve(address(protocol), amount);
        try protocol.swap(c, false, amount, 0, t) {} catch (bytes memory err) {
            // the only acceptable sell failure is the reserve floor
            require(bytes4(err) == UpsideProtocol.InsufficientLiquidity.selector, "unexpected sell revert");
        }
        vm.stopPrank();
    }

    function claimDeployer(uint256 coin) external {
        vm.prank(deployer);
        protocol.claimDeployerFees(coins[coin % coins.length], deployer);
    }
}

contract InvariantTest is BaseTest {
    Handler handler;
    address[] coins;

    function setUp() public override {
        super.setUp();
        useStub();
        coins.push(tokenize("https://a"));
        coins.push(tokenize("https://b"));
        handler = new Handler(protocol, usdc, coins, deployer);
        targetContract(address(handler));
    }

    /// Protocol always holds enough USDC for every coin's real reserves plus protocol fees.
    function invariant_usdcSolvent() public view {
        uint256 owed = protocol.claimableProtocolFees();
        for (uint256 i; i < coins.length; i++) {
            (, , uint256 l, , ) = protocol.metaCoinInfoMap(coins[i]);
            owed += l - protocol.INITIAL_LIQUIDITY_RESERVES();
        }
        assertGe(usdc.balanceOf(address(protocol)), owed);
    }

    /// Protocol always holds enough of each MetaCoin for its reserves plus claimable deployer fees.
    function invariant_metaCoinSolvent() public view {
        for (uint256 i; i < coins.length; i++) {
            (, , , uint256 m, ) = protocol.metaCoinInfoMap(coins[i]);
            uint256 owed = m + protocol.claimableDeployerFees(coins[i], deployer);
            assertGe(IERC20(coins[i]).balanceOf(address(protocol)), owed);
        }
    }

    /// Nobody can end up with more MetaCoin than the fixed supply.
    function invariant_supplyFixed() public view {
        for (uint256 i; i < coins.length; i++) {
            assertEq(IERC20(coins[i]).totalSupply(), 1_000_000e18);
        }
    }
}
