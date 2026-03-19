// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";

library PriceCondition {
    function meetsTarget(uint160 observedSqrtPriceX96, uint160 targetSqrtPriceX96, bool priceAbove)
        internal
        pure
        returns (bool)
    {
        if (targetSqrtPriceX96 == 0 || observedSqrtPriceX96 == 0) {
            return false;
        }
        return priceAbove ? observedSqrtPriceX96 >= targetSqrtPriceX96 : observedSqrtPriceX96 <= targetSqrtPriceX96;
    }

    function tickToSqrtPriceX96(int24 tick) internal pure returns (uint160) {
        return TickMath.getSqrtPriceAtTick(tick);
    }

    /// @notice Converts sqrtPriceX96 to a Q128 fixed point price representation.
    function sqrtPriceX96ToPriceX128(uint160 sqrtPriceX96) internal pure returns (uint256) {
        return FullMath.mulDiv(uint256(sqrtPriceX96), uint256(sqrtPriceX96), 1 << 64);
    }
}
