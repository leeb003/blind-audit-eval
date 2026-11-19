// SPDX-License-Identifier: MIT
pragma solidity 0.8.13;
import "./CrossBase.t.sol";
contract SanityTest is CrossBase {
    function test_setup() public {
        assertTrue(address(gauge) != address(0));
        assertTrue(gaugeManager.isGauge(address(gauge)));
    }
}
