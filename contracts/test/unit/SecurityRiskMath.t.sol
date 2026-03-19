// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {SecurityRiskMath} from "src/libraries/SecurityRiskMath.sol";

contract SecurityRiskMathHarness {
    function absInt256Wrap(int256 value) external pure returns (uint256) {
        return SecurityRiskMath.absInt256(value);
    }

    function absInt128Wrap(int128 value) external pure returns (uint256) {
        return SecurityRiskMath.absInt128(value);
    }

    function boundedBpsRatioWrap(uint256 numerator, uint256 denominator) external pure returns (uint32) {
        return SecurityRiskMath.boundedBpsRatio(numerator, denominator);
    }

    function relativeDifferenceBpsWrap(uint256 a, uint256 b) external pure returns (uint32) {
        return SecurityRiskMath.relativeDifferenceBps(a, b);
    }

    function liquidityImbalanceBpsWrap(uint256 amount0, uint256 amount1) external pure returns (uint32) {
        return SecurityRiskMath.liquidityImbalanceBps(amount0, amount1);
    }

    function rollingAverageWrap(uint128 previous, uint256 current, uint32 window) external pure returns (uint128) {
        return SecurityRiskMath.rollingAverage(previous, current, window);
    }
}

contract SecurityRiskMathUnitTest is Test {
    SecurityRiskMathHarness internal harness;

    function setUp() public {
        harness = new SecurityRiskMathHarness();
    }

    function testAbsHelpers() public view {
        assertEq(harness.absInt256Wrap(-7), 7);
        assertEq(harness.absInt256Wrap(9), 9);

        assertEq(harness.absInt128Wrap(-5), 5);
        assertEq(harness.absInt128Wrap(11), 11);
    }

    function testBoundedRatioHandlesZeroInputsAndCap() public view {
        assertEq(harness.boundedBpsRatioWrap(0, 100), 0);
        assertEq(harness.boundedBpsRatioWrap(100, 0), 0);

        uint32 capped = harness.boundedBpsRatioWrap(uint256(type(uint32).max) + 1, 1);
        assertEq(capped, type(uint32).max);
    }

    function testRelativeDifferenceAndLiquidityImbalance() public view {
        assertEq(harness.relativeDifferenceBpsWrap(0, 10), 0);
        assertEq(harness.relativeDifferenceBpsWrap(10, 0), 0);
        assertEq(harness.relativeDifferenceBpsWrap(100, 120), 2_000);

        assertEq(harness.liquidityImbalanceBpsWrap(0, 0), 0);
        assertEq(harness.liquidityImbalanceBpsWrap(100, 50), 5_000);
        assertEq(harness.liquidityImbalanceBpsWrap(100, 100), 0);
    }

    function testRollingAverageRespectsWindowAndCapsCurrent() public view {
        assertEq(harness.rollingAverageWrap(0, 42, 1), 42);
        assertEq(harness.rollingAverageWrap(100, 200, 2), 150);

        uint128 cappedCurrent = harness.rollingAverageWrap(1, type(uint256).max, 1);
        assertEq(cappedCurrent, type(uint128).max);
    }
}
