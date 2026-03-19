// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

library SecurityRiskMath {
    uint256 internal constant BPS = 10_000;

    function absInt256(int256 value) internal pure returns (uint256) {
        if (value < 0) {
            return uint256(-value);
        }
        return uint256(value);
    }

    function absInt128(int128 value) internal pure returns (uint256) {
        if (value < 0) {
            return uint256(uint128(-value));
        }
        return uint256(uint128(value));
    }

    function boundedBpsRatio(uint256 numerator, uint256 denominator) internal pure returns (uint32) {
        if (numerator == 0 || denominator == 0) {
            return 0;
        }

        uint256 ratio = (numerator * BPS) / denominator;
        if (ratio > type(uint32).max) {
            return type(uint32).max;
        }
        return uint32(ratio);
    }

    function relativeDifferenceBps(uint256 a, uint256 b) internal pure returns (uint32) {
        if (a == 0 || b == 0) {
            return 0;
        }

        uint256 diff = a > b ? a - b : b - a;
        return boundedBpsRatio(diff, a);
    }

    function liquidityImbalanceBps(uint256 amount0Abs, uint256 amount1Abs) internal pure returns (uint32) {
        if (amount0Abs == 0 && amount1Abs == 0) {
            return 0;
        }

        uint256 larger = amount0Abs > amount1Abs ? amount0Abs : amount1Abs;
        uint256 smaller = amount0Abs > amount1Abs ? amount1Abs : amount0Abs;
        return boundedBpsRatio(larger - smaller, larger);
    }

    function rollingAverage(uint128 previous, uint256 current, uint32 window) internal pure returns (uint128) {
        if (current > type(uint128).max) {
            current = type(uint128).max;
        }

        if (window <= 1) {
            return uint128(current);
        }

        uint256 weighted = uint256(previous) * uint256(window - 1);
        uint256 next = (weighted + current) / window;
        return uint128(next);
    }
}
