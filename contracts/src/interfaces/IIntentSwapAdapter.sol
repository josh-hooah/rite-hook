// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

interface IIntentSwapAdapter {
    struct SwapRequest {
        bytes32 intentId;
        address tokenIn;
        address tokenOut;
        PoolKey poolKey;
        bool zeroForOne;
        uint256 amountIn;
        uint256 amountOutMin;
        bytes hookData;
        address recipient;
        uint256 deadline;
    }

    function executeSwap(SwapRequest calldata request) external returns (uint256 amountOut);
}
