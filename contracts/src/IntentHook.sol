// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {BaseHook} from "@uniswap/v4-periphery/src/utils/BaseHook.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

import {VolatilityMath} from "./libraries/VolatilityMath.sol";

contract IntentHook is BaseHook, Ownable {
    using PoolIdLibrary for PoolKey;
    using BalanceDeltaLibrary for BalanceDelta;

    struct PoolTelemetry {
        uint160 sqrtPriceX96;
        int24 tick;
        uint32 rollingVolatilityBps;
        uint64 updatedAt;
        uint32 beforeSwapCount;
        uint32 afterSwapCount;
    }

    error InvalidVolatilityWindow();

    event HookConfigured(uint32 volatilityWindow);
    event BeforeSwapObserved(
        bytes32 indexed poolId,
        address indexed sender,
        bool zeroForOne,
        int256 amountSpecified,
        bytes32 hookDataHash
    );
    event SwapTelemetry(
        bytes32 indexed poolId,
        address indexed sender,
        int24 tick,
        uint160 sqrtPriceX96,
        uint32 rollingVolatilityBps,
        int128 amount0Delta,
        int128 amount1Delta,
        uint64 observedAt
    );

    uint32 public volatilityWindow;

    mapping(PoolId => PoolTelemetry) private _poolTelemetry;

    constructor(IPoolManager manager, address initialOwner, uint32 volatilityWindow_) BaseHook(manager) Ownable(initialOwner) {
        _setVolatilityWindow(volatilityWindow_);
    }

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: false,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    function setVolatilityWindow(uint32 volatilityWindow_) external onlyOwner {
        _setVolatilityWindow(volatilityWindow_);
    }

    function telemetryByPoolKey(PoolKey calldata key) external view returns (PoolTelemetry memory) {
        return _poolTelemetry[key.toId()];
    }

    function telemetryByPoolId(bytes32 poolId) external view returns (PoolTelemetry memory) {
        return _poolTelemetry[PoolId.wrap(poolId)];
    }

    function _beforeSwap(address sender, PoolKey calldata key, SwapParams calldata params, bytes calldata hookData)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        PoolId poolId = key.toId();
        _poolTelemetry[poolId].beforeSwapCount += 1;

        emit BeforeSwapObserved(
            PoolId.unwrap(poolId), sender, params.zeroForOne, params.amountSpecified, keccak256(hookData)
        );

        return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    function _afterSwap(address sender, PoolKey calldata key, SwapParams calldata, BalanceDelta delta, bytes calldata)
        internal
        override
        returns (bytes4, int128)
    {
        PoolId poolId = key.toId();
        PoolTelemetry storage telemetry = _poolTelemetry[poolId];
        telemetry.afterSwapCount += 1;

        (uint160 sqrtPriceX96, int24 tick,,) = StateLibrary.getSlot0(poolManager, poolId);
        telemetry.rollingVolatilityBps = VolatilityMath.rollingAbsTickDelta(
            telemetry.rollingVolatilityBps, telemetry.tick, tick, volatilityWindow
        );
        telemetry.sqrtPriceX96 = sqrtPriceX96;
        telemetry.tick = tick;
        telemetry.updatedAt = uint64(block.timestamp);

        _emitSwapTelemetry(poolId, sender, tick, sqrtPriceX96, telemetry.rollingVolatilityBps, delta, telemetry.updatedAt);

        return (BaseHook.afterSwap.selector, 0);
    }

    function _setVolatilityWindow(uint32 volatilityWindow_) internal {
        if (volatilityWindow_ == 0 || volatilityWindow_ > 7200) {
            revert InvalidVolatilityWindow();
        }
        volatilityWindow = volatilityWindow_;
        emit HookConfigured(volatilityWindow_);
    }

    function _emitSwapTelemetry(
        PoolId poolId,
        address sender,
        int24 tick,
        uint160 sqrtPriceX96,
        uint32 rollingVolatilityBps,
        BalanceDelta delta,
        uint64 updatedAt
    ) internal {
        emit SwapTelemetry(
            PoolId.unwrap(poolId),
            sender,
            tick,
            sqrtPriceX96,
            rollingVolatilityBps,
            delta.amount0(),
            delta.amount1(),
            updatedAt
        );
    }
}
