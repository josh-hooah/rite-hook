// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {BaseHook} from "@uniswap/v4-periphery/src/utils/BaseHook.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

import {VolatilityMath} from "src/libraries/VolatilityMath.sol";
import {MitigationPayload, PoolTelemetry, ProtectionConfig, ProtectionState} from "src/libraries/SecurityTypes.sol";
import {SecurityRiskMath} from "src/libraries/SecurityRiskMath.sol";

/**
 * @title SecurityHook
 * @notice Uniswap v4 hook firewall that emits risk telemetry and enforces mitigation state.
 * @custom:security-contact jesuorobonosakhare873@gmail.com
 */
contract SecurityHook is BaseHook, Ownable2Step {
    using PoolIdLibrary for PoolKey;
    using BalanceDeltaLibrary for BalanceDelta;
    using LPFeeLibrary for uint24;

    uint256 internal constant Q96 = 2 ** 96;

    error SecurityHook__ZeroAddress();
    error SecurityHook__InvalidVolatilityWindow();
    error SecurityHook__InvalidProtectionConfig();
    error SecurityHook__UnauthorizedExecutor(address caller);
    error SecurityHook__PoolPaused(bytes32 poolId, uint64 pauseUntil);
    error SecurityHook__SwapThrottled(bytes32 poolId, uint256 attemptedAmount, uint256 maxAllowed);

    event SecurityExecutorUpdated(address indexed securityExecutor);
    event VolatilityWindowUpdated(uint32 volatilityWindow);
    event PoolProtectionConfigUpdated(
        bytes32 indexed poolId, uint24 baseFeePips, uint24 maxFeePips, uint16 maxThrottleBps, uint64 maxPauseSeconds
    );
    event ProtectionApplied(
        bytes32 indexed poolId,
        uint256 indexed nonce,
        uint16 riskScoreBps,
        uint24 dynamicFeePips,
        uint16 throttleBps,
        uint128 maxTradeSize,
        uint64 pauseUntil,
        bytes32 reason
    );
    event SecurityTelemetry(
        bytes32 indexed poolId,
        address indexed sender,
        bool zeroForOne,
        int256 amountSpecified,
        int24 tick,
        uint160 sqrtPriceX96,
        uint32 rollingVolatilityBps,
        uint32 priceDeviationBps,
        uint32 slippageBps,
        uint32 liquidityImbalanceBps,
        uint128 rollingVolume,
        uint64 observedAt,
        uint64 sequence
    );

    uint32 public volatilityWindow;
    address public securityExecutor;

    mapping(PoolId => PoolTelemetry) private _poolTelemetry;
    mapping(PoolId => ProtectionConfig) private _poolProtectionConfig;
    mapping(PoolId => ProtectionState) private _poolProtectionState;

    constructor(IPoolManager manager, address initialOwner, address securityExecutor_, uint32 volatilityWindow_)
        BaseHook(manager)
        Ownable(initialOwner)
    {
        _setVolatilityWindow(volatilityWindow_);
        _setSecurityExecutor(securityExecutor_);
    }

    /*//////////////////////////////////////////////////////////////
                            EXTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function getHookPermissions() public pure override returns (Hooks.Permissions memory permissions) {
        permissions = Hooks.Permissions({
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

    function setSecurityExecutor(address securityExecutor_) external onlyOwner {
        _setSecurityExecutor(securityExecutor_);
    }

    function setVolatilityWindow(uint32 volatilityWindow_) external onlyOwner {
        _setVolatilityWindow(volatilityWindow_);
    }

    function setPoolProtectionConfig(bytes32 poolIdRaw, ProtectionConfig calldata config) external onlyOwner {
        _validateProtectionConfig(config);

        PoolId poolId = PoolId.wrap(poolIdRaw);
        _poolProtectionConfig[poolId] = config;

        emit PoolProtectionConfigUpdated(
            poolIdRaw, config.baseFeePips, config.maxFeePips, config.maxThrottleBps, config.maxPauseSeconds
        );
    }

    function applyProtection(bytes32 poolIdRaw, uint256 nonce, MitigationPayload calldata payload)
        external
        returns (bool applied)
    {
        if (msg.sender != securityExecutor) {
            revert SecurityHook__UnauthorizedExecutor(msg.sender);
        }

        PoolId poolId = PoolId.wrap(poolIdRaw);
        ProtectionState storage protection = _poolProtectionState[poolId];
        if (nonce <= protection.nonce) {
            return false;
        }

        ProtectionConfig memory config = _effectiveConfig(_poolProtectionConfig[poolId]);
        if (payload.dynamicFeePips > config.maxFeePips || payload.throttleBps > config.maxThrottleBps) {
            revert SecurityHook__InvalidProtectionConfig();
        }

        uint64 pauseFor = payload.pauseSeconds;
        if (pauseFor > config.maxPauseSeconds) {
            pauseFor = config.maxPauseSeconds;
        }

        protection.nonce = nonce;
        protection.currentFeePips = payload.dynamicFeePips;
        protection.throttleBps = payload.throttleBps;
        protection.maxTradeSize = payload.maxTradeSize;
        protection.pauseUntil = pauseFor == 0 ? 0 : uint64(block.timestamp) + pauseFor;
        protection.lastRiskScoreBps = payload.riskScoreBps;
        protection.updatedAt = uint64(block.timestamp);

        emit ProtectionApplied(
            poolIdRaw,
            nonce,
            payload.riskScoreBps,
            protection.currentFeePips,
            protection.throttleBps,
            protection.maxTradeSize,
            protection.pauseUntil,
            payload.reason
        );

        return true;
    }

    function telemetryByPoolId(bytes32 poolId) external view returns (PoolTelemetry memory telemetry) {
        telemetry = _poolTelemetry[PoolId.wrap(poolId)];
    }

    function telemetryByPoolKey(PoolKey calldata key) external view returns (PoolTelemetry memory telemetry) {
        telemetry = _poolTelemetry[key.toId()];
    }

    function protectionStateByPoolId(bytes32 poolId) external view returns (ProtectionState memory protection) {
        protection = _poolProtectionState[PoolId.wrap(poolId)];
    }

    function protectionConfigByPoolId(bytes32 poolId) external view returns (ProtectionConfig memory config) {
        config = _effectiveConfig(_poolProtectionConfig[PoolId.wrap(poolId)]);
    }

    /*//////////////////////////////////////////////////////////////
                      INTERNAL STATE-CHANGING FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function _beforeSwap(address, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        PoolId poolId = key.toId();
        PoolTelemetry storage telemetry = _poolTelemetry[poolId];
        ProtectionState storage protection = _poolProtectionState[poolId];

        telemetry.beforeSwapCount += 1;
        _enforceProtection(poolId, telemetry, protection, params);

        uint24 feeOverride;
        uint24 candidateFee = protection.currentFeePips;
        if (candidateFee == 0) {
            candidateFee = _effectiveConfig(_poolProtectionConfig[poolId]).baseFeePips;
        }

        if (candidateFee > 0 && key.fee.isDynamicFee()) {
            feeOverride = candidateFee | LPFeeLibrary.OVERRIDE_FEE_FLAG;
        }

        return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, feeOverride);
    }

    function _afterSwap(address sender, PoolKey calldata key, SwapParams calldata params, BalanceDelta delta, bytes calldata)
        internal
        override
        returns (bytes4, int128)
    {
        _recordAfterSwap(sender, key, params, delta);
        return (BaseHook.afterSwap.selector, 0);
    }

    /*//////////////////////////////////////////////////////////////
                             INTERNAL HELPERS
    //////////////////////////////////////////////////////////////*/

    function _recordAfterSwap(address sender, PoolKey calldata key, SwapParams calldata params, BalanceDelta delta) internal
    {
        PoolId poolId = key.toId();
        PoolTelemetry storage telemetry = _poolTelemetry[poolId];

        telemetry.afterSwapCount += 1;

        (uint160 sqrtPriceX96, int24 tick,,) = StateLibrary.getSlot0(poolManager, poolId);
        uint160 previousSqrtPriceX96 = telemetry.sqrtPriceX96;
        int24 previousTick = telemetry.tick;

        telemetry.rollingVolatilityBps =
            VolatilityMath.rollingAbsTickDelta(telemetry.rollingVolatilityBps, previousTick, tick, volatilityWindow);
        telemetry.priceDeviationBps = SecurityRiskMath.relativeDifferenceBps(uint256(previousSqrtPriceX96), uint256(sqrtPriceX96));

        uint256 amountSpecifiedAbs = SecurityRiskMath.absInt256(params.amountSpecified);
        telemetry.rollingVolume = SecurityRiskMath.rollingAverage(telemetry.rollingVolume, amountSpecifiedAbs, volatilityWindow);

        {
            uint256 amount0Abs = SecurityRiskMath.absInt128(delta.amount0());
            uint256 amount1Abs = SecurityRiskMath.absInt128(delta.amount1());
            telemetry.slippageBps = _slippageAgainstSpotBps(sqrtPriceX96, amount0Abs, amount1Abs);
            telemetry.liquidityImbalanceBps = SecurityRiskMath.liquidityImbalanceBps(amount0Abs, amount1Abs);
        }

        telemetry.sqrtPriceX96 = sqrtPriceX96;
        telemetry.tick = tick;
        telemetry.observedAt = uint64(block.timestamp);
        telemetry.sequence += 1;

        PoolTelemetry memory snapshot = telemetry;
        _emitTelemetry(poolId, sender, params.zeroForOne, params.amountSpecified, tick, sqrtPriceX96, snapshot);
    }

    /*//////////////////////////////////////////////////////////////
                               INTERNAL VIEW
    //////////////////////////////////////////////////////////////*/

    function _enforceProtection(
        PoolId poolId,
        PoolTelemetry storage telemetry,
        ProtectionState storage protection,
        SwapParams calldata params
    ) internal view {
        if (protection.pauseUntil != 0 && block.timestamp <= protection.pauseUntil) {
            revert SecurityHook__PoolPaused(PoolId.unwrap(poolId), protection.pauseUntil);
        }

        uint256 amountSpecifiedAbs = SecurityRiskMath.absInt256(params.amountSpecified);
        if (protection.maxTradeSize > 0 && amountSpecifiedAbs > protection.maxTradeSize) {
            revert SecurityHook__SwapThrottled(PoolId.unwrap(poolId), amountSpecifiedAbs, protection.maxTradeSize);
        }

        if (protection.throttleBps > 0 && telemetry.rollingVolume > 0) {
            uint256 maxAllowed = (uint256(telemetry.rollingVolume) * protection.throttleBps) / 10_000;
            if (maxAllowed == 0) {
                maxAllowed = 1;
            }
            if (amountSpecifiedAbs > maxAllowed) {
                revert SecurityHook__SwapThrottled(PoolId.unwrap(poolId), amountSpecifiedAbs, maxAllowed);
            }
        }
    }

    function _setSecurityExecutor(address securityExecutor_) internal {
        if (securityExecutor_ == address(0)) {
            revert SecurityHook__ZeroAddress();
        }
        securityExecutor = securityExecutor_;
        emit SecurityExecutorUpdated(securityExecutor_);
    }

    function _setVolatilityWindow(uint32 volatilityWindow_) internal {
        if (volatilityWindow_ == 0 || volatilityWindow_ > 7_200) {
            revert SecurityHook__InvalidVolatilityWindow();
        }
        volatilityWindow = volatilityWindow_;
        emit VolatilityWindowUpdated(volatilityWindow_);
    }

    function _validateProtectionConfig(ProtectionConfig memory config) internal pure {
        if (
            config.baseFeePips > config.maxFeePips || config.maxFeePips > LPFeeLibrary.MAX_LP_FEE
                || config.maxThrottleBps > 10_000 || config.maxPauseSeconds == 0
        ) {
            revert SecurityHook__InvalidProtectionConfig();
        }
    }

    function _effectiveConfig(ProtectionConfig memory config) internal pure returns (ProtectionConfig memory effective) {
        effective = config;
        if (effective.maxFeePips == 0 && effective.maxThrottleBps == 0 && effective.maxPauseSeconds == 0) {
            effective = ProtectionConfig({
                baseFeePips: 0,
                maxFeePips: 300_000,
                maxThrottleBps: 10_000,
                maxPauseSeconds: 3_600
            });
        }
    }

    function _slippageAgainstSpotBps(uint160 sqrtPriceX96, uint256 amount0Abs, uint256 amount1Abs)
        internal
        pure
        returns (uint32)
    {
        if (sqrtPriceX96 == 0 || amount0Abs == 0 || amount1Abs == 0) {
            return 0;
        }

        uint256 expectedPriceX96 = (uint256(sqrtPriceX96) * uint256(sqrtPriceX96)) / Q96;
        if (expectedPriceX96 == 0) {
            return 0;
        }

        uint256 tradePriceX96 = (amount1Abs * Q96) / amount0Abs;
        return SecurityRiskMath.relativeDifferenceBps(expectedPriceX96, tradePriceX96);
    }

    function _emitTelemetry(
        PoolId poolId,
        address sender,
        bool zeroForOne,
        int256 amountSpecified,
        int24 tick,
        uint160 sqrtPriceX96,
        PoolTelemetry memory telemetry
    ) internal {
        emit SecurityTelemetry(
            PoolId.unwrap(poolId),
            sender,
            zeroForOne,
            amountSpecified,
            tick,
            sqrtPriceX96,
            telemetry.rollingVolatilityBps,
            telemetry.priceDeviationBps,
            telemetry.slippageBps,
            telemetry.liquidityImbalanceBps,
            telemetry.rollingVolume,
            telemetry.observedAt,
            telemetry.sequence
        );
    }
}
