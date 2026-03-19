// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

/// @notice Supported trigger families.
enum TriggerType {
    PRICE,
    TIME,
    VOLATILITY
}

/// @notice Canonical intent lifecycle states.
enum IntentStatus {
    NONE,
    PENDING,
    EXECUTED,
    CANCELLED,
    EXPIRED
}

/// @notice Trigger configuration packed into a single struct for storage and eventing.
struct TriggerConfig {
    uint160 targetSqrtPriceX96;
    bool priceAbove;
    uint64 startTime;
    uint64 endTime;
    uint64 interval;
    uint32 volatilityBps;
    bool volatilityAbove;
    uint16 chunkBips;
}

/// @notice User-provided parameters for creating a new intent.
struct IntentParams {
    PoolKey poolKey;
    address tokenIn;
    address tokenOut;
    bool zeroForOne;
    uint256 amountIn;
    uint256 amountOutMin;
    TriggerType triggerType;
    TriggerConfig trigger;
    uint64 expiry;
}

/// @notice Persisted intent state.
struct Intent {
    bytes32 intentId;
    address user;
    bytes32 poolId;
    PoolKey poolKey;
    address tokenIn;
    address tokenOut;
    bool zeroForOne;
    uint256 amountIn;
    uint256 amountOutMin;
    TriggerType triggerType;
    TriggerConfig trigger;
    uint64 expiry;
    uint64 createdAt;
    uint64 lastExecutionAt;
    uint256 nonce;
    uint256 remainingAmount;
    IntentStatus status;
}

/// @notice Canonical execution record kept for telemetry/API surfaces.
struct ExecutionResult {
    uint64 executedAt;
    uint256 executedAmount;
    uint256 outputAmount;
    bytes32 reason;
}

/// @notice Reactive-provided context for deterministic execution checks.
struct ExecutionContext {
    uint160 observedSqrtPriceX96;
    int24 observedTick;
    uint32 observedVolatilityBps;
    uint256 maxAmountIn;
    bytes hookData;
}
