// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.24;

import "forge-std/Test.sol";
import "../contracts/UpsideProtocol.sol";
import "../contracts/UpsideMetaCoin.sol";
import "../contracts/UpsideStaking.sol";
import "../contracts/UpsideStakingStub.sol";
import "../contracts/mock/USDCMock.sol";

/// Shared setup for PoCs. Fee values are plausible guesses; none of the PoCs depend on them.
abstract contract BaseTest is Test {
    address owner = makeAddr("owner");
    address deployer = makeAddr("deployer");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address feeSink = makeAddr("feeSink");

    USDCMock usdc;
    UpsideProtocol protocol;

    function setUp() public virtual {
        usdc = new USDCMock();
        protocol = new UpsideProtocol(owner);

        vm.startPrank(owner);
        protocol.init(address(usdc));
        protocol.setFeeInfo(
            UpsideProtocol.FeeInfo({
                tokenizeFeeDestinationAddress: feeSink,
                swapFeeDecayInterval: 60,
                tokenizeFeeEnabled: false,
                swapFeeStartingBp: 9900,
                swapFeeDecayBp: 100,
                swapFeeFinalBp: 100,
                swapFeeSellBp: 100,
                swapFeeDeployerBp: 1000
            })
        );
        vm.stopPrank();

        usdc.mint(alice, 1_000_000e6);
        usdc.mint(bob, 1_000_000e6);
    }

    /// Protocol launches with the stub, as its own comments describe ("if the decision is not to enable staking just yet")
    function useStub() internal returns (UpsideStakingStub stub) {
        stub = new UpsideStakingStub(owner);
        vm.startPrank(owner);
        stub.setFeeDestinationAddress(feeSink);
        protocol.setStakingContractAddress(address(stub));
        vm.stopPrank();
    }

    /// Real staking must be owned by the protocol, because tokenize() calls the onlyOwner whitelistStakingToken()
    function useStaking() internal returns (UpsideStaking staking) {
        staking = new UpsideStaking(address(protocol), feeSink);
        vm.prank(owner);
        protocol.setStakingContractAddress(address(staking));
    }

    function tokenize(string memory url) internal returns (address coin) {
        vm.prank(deployer);
        coin = protocol.tokenize(url, address(0));
    }

    function buy(address who, address coin, uint256 usdcAmount) internal returns (uint256 out) {
        vm.startPrank(who);
        usdc.approve(address(protocol), usdcAmount);
        out = protocol.swap(coin, true, usdcAmount, 0, who);
        vm.stopPrank();
    }

    function sell(address who, address coin, uint256 amount) internal returns (uint256 out) {
        vm.startPrank(who);
        IERC20(coin).approve(address(protocol), amount);
        out = protocol.swap(coin, false, amount, 0, who);
        vm.stopPrank();
    }
}
