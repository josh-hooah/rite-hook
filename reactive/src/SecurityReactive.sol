// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {AbstractReactive, IReactive} from "./lib/ReactiveBase.sol";

/**
 * @title SecurityReactive
 * @notice Reactive risk engine that scores hook telemetry and emits mitigation callbacks.
 * @dev Callback payload first argument is placeholder `address(0)` and is overwritten by ReactVM ID.
 */
contract SecurityReactive is AbstractReactive {
    uint16 internal constant BPS = 10_000;

    uint16 internal constant VOLATILITY_WEIGHT_BPS = 2_000;
    uint16 internal constant PRICE_WEIGHT_BPS = 2_000;
    uint16 internal constant SLIPPAGE_WEIGHT_BPS = 1_800;
    uint16 internal constant IMBALANCE_WEIGHT_BPS = 1_400;
    uint16 internal constant VOLUME_WEIGHT_BPS = 1_600;
    uint16 internal constant TEMPORAL_WEIGHT_BPS = 900;
    uint16 internal constant MEV_WEIGHT_BPS = 700;

    error SecurityReactive__NotOwner();
    error SecurityReactive__InvalidConfig();
    error SecurityReactive__InvalidRiskConfig();

    event CallbackGasLimitUpdated(uint64 callbackGasLimit);
    event RiskConfigUpdated(RiskConfig config);
    event RiskScored(
        bytes32 indexed poolId,
        uint16 riskScoreBps,
        uint16 volatilityComponent,
        uint16 priceDeviationComponent,
        uint16 slippageComponent,
        uint16 liquidityImbalanceComponent,
        uint16 volumeSpikeComponent,
        uint16 temporalCorrelationComponent,
        uint16 mevHeuristicComponent,
        uint64 observedAt,
        uint64 sequence
    );
    event CallbackQueued(bytes32 indexed poolId, uint256 indexed nonce, uint8 mode, uint16 riskScoreBps, bytes32 reason);

    enum MitigationMode {
        NONE,
        ADAPTIVE_FEE,
        THROTTLE,
        PAUSE,
        COMBINED
    }

    struct MitigationPayload {
        uint24 dynamicFeePips;
        uint16 throttleBps;
        uint128 maxTradeSize;
        uint64 pauseSeconds;
        uint16 riskScoreBps;
        MitigationMode mode;
        bytes32 reason;
    }

    struct RiskConfig {
        uint32 volatilityThresholdBps;
        uint32 priceDeviationThresholdBps;
        uint32 slippageThresholdBps;
        uint32 imbalanceThresholdBps;
        uint32 volumeSpikeThresholdBps;
        uint16 highRiskScoreBps;
        uint16 criticalRiskScoreBps;
        uint24 highDynamicFeePips;
        uint24 criticalDynamicFeePips;
        uint16 highThrottleBps;
        uint16 criticalThrottleBps;
        uint64 highPauseSeconds;
        uint64 criticalPauseSeconds;
        uint64 temporalWindowSeconds;
        uint64 mitigationCooldownSeconds;
    }

    struct RiskComponents {
        uint16 volatility;
        uint16 priceDeviation;
        uint16 slippage;
        uint16 liquidityImbalance;
        uint16 volumeSpike;
        uint16 temporalCorrelation;
        uint16 mevHeuristic;
    }

    struct PoolRiskState {
        uint128 lastRollingVolume;
        uint64 lastObservedAt;
        uint64 lastMitigationAt;
        uint64 lastSequence;
        uint16 lastRiskScoreBps;
        bool lastDirectionZeroForOne;
        uint256 mitigationNonce;
    }

    uint256 internal constant SECURITY_TELEMETRY_TOPIC_0 =
        uint256(
            keccak256(
                "SecurityTelemetry(bytes32,address,bool,int256,int24,uint160,uint32,uint32,uint32,uint32,uint128,uint64,uint64)"
            )
        );

    bytes32 internal constant REASON_ELEVATED_RISK = keccak256("ELEVATED_RISK");
    bytes32 internal constant REASON_CRITICAL_RISK = keccak256("CRITICAL_RISK");

    address public owner;
    uint256 public immutable originChainId;
    uint256 public immutable destinationChainId;
    address public immutable securityHook;
    address public immutable securityExecutor;

    uint64 public callbackGasLimit;
    RiskConfig public riskConfig;

    mapping(bytes32 => bool) public processedLogs;
    mapping(bytes32 => PoolRiskState) public poolRiskState;

    constructor(
        address owner_,
        uint256 originChainId_,
        uint256 destinationChainId_,
        address securityHook_,
        address securityExecutor_,
        uint64 callbackGasLimit_
    ) payable {
        if (
            owner_ == address(0) || securityHook_ == address(0) || securityExecutor_ == address(0)
                || callbackGasLimit_ == 0
        ) {
            revert SecurityReactive__InvalidConfig();
        }

        owner = owner_;
        originChainId = originChainId_;
        destinationChainId = destinationChainId_;
        securityHook = securityHook_;
        securityExecutor = securityExecutor_;
        callbackGasLimit = callbackGasLimit_;
        riskConfig = _defaultRiskConfig();

        if (!vm) {
            service.subscribe(
                originChainId,
                securityHook,
                SECURITY_TELEMETRY_TOPIC_0,
                REACTIVE_IGNORE,
                REACTIVE_IGNORE,
                REACTIVE_IGNORE
            );
        }
    }

    modifier onlyOwner() {
        if (msg.sender != owner) {
            revert SecurityReactive__NotOwner();
        }
        _;
    }

    function setCallbackGasLimit(uint64 callbackGasLimit_) external onlyOwner {
        if (callbackGasLimit_ == 0) {
            revert SecurityReactive__InvalidConfig();
        }
        callbackGasLimit = callbackGasLimit_;
        emit CallbackGasLimitUpdated(callbackGasLimit_);
    }

    function setRiskConfig(RiskConfig calldata config) external onlyOwner {
        _validateRiskConfig(config);
        riskConfig = config;
        emit RiskConfigUpdated(config);
    }

    function getRiskConfig() external view returns (RiskConfig memory config) {
        config = riskConfig;
    }

    function getPoolRiskState(bytes32 poolId) external view returns (PoolRiskState memory state) {
        state = poolRiskState[poolId];
    }

    function react(LogRecord calldata log) external vmOnly {
        bytes32 logKey = keccak256(abi.encode(log.chain_id, log.tx_hash, log.log_index));
        if (processedLogs[logKey]) {
            return;
        }
        processedLogs[logKey] = true;

        if (log.chain_id != originChainId || log._contract != securityHook || log.topic_0 != SECURITY_TELEMETRY_TOPIC_0) {
            return;
        }

        _onSecurityTelemetry(log);
    }

    function _onSecurityTelemetry(LogRecord calldata log) internal {
        bytes32 poolId = bytes32(log.topic_1);

        (
            bool zeroForOne,
            int256 amountSpecifiedIgnored,
            int24 tickIgnored,
            uint160 sqrtPriceX96Ignored,
            uint32 rollingVolatilityBps,
            uint32 priceDeviationBps,
            uint32 slippageBps,
            uint32 liquidityImbalanceBps,
            uint128 rollingVolume,
            uint64 observedAt,
            uint64 sequence
        ) = abi.decode(log.data, (bool, int256, int24, uint160, uint32, uint32, uint32, uint32, uint128, uint64, uint64));
        amountSpecifiedIgnored;
        tickIgnored;
        sqrtPriceX96Ignored;

        PoolRiskState storage state = poolRiskState[poolId];

        RiskComponents memory components = _computeComponents(
            state,
            zeroForOne,
            observedAt,
            rollingVolatilityBps,
            priceDeviationBps,
            slippageBps,
            liquidityImbalanceBps,
            rollingVolume
        );

        uint16 riskScoreBps = _sumComponents(components);

        emit RiskScored(
            poolId,
            riskScoreBps,
            components.volatility,
            components.priceDeviation,
            components.slippage,
            components.liquidityImbalance,
            components.volumeSpike,
            components.temporalCorrelation,
            components.mevHeuristic,
            observedAt,
            sequence
        );

        state.lastRollingVolume = rollingVolume;
        state.lastObservedAt = observedAt;
        state.lastSequence = sequence;
        state.lastDirectionZeroForOne = zeroForOne;
        state.lastRiskScoreBps = riskScoreBps;

        if (riskScoreBps < riskConfig.highRiskScoreBps) {
            return;
        }

        if (
            state.lastMitigationAt != 0
                && observedAt < uint256(state.lastMitigationAt) + riskConfig.mitigationCooldownSeconds
        ) {
            return;
        }

        (MitigationPayload memory payload, bytes32 reason) = _buildMitigationPayload(riskScoreBps, rollingVolume, components);
        uint256 nonce = state.mitigationNonce + 1;

        bytes memory mitigationData = abi.encode(payload);
        bytes memory callbackPayload = abi.encodeWithSignature(
            "applyMitigation(address,bytes32,uint256,bytes)", address(0), poolId, nonce, mitigationData
        );

        emit Callback(destinationChainId, securityExecutor, callbackGasLimit, callbackPayload);
        emit CallbackQueued(poolId, nonce, uint8(payload.mode), payload.riskScoreBps, reason);

        state.mitigationNonce = nonce;
        state.lastMitigationAt = observedAt;
    }

    function _computeComponents(
        PoolRiskState storage state,
        bool zeroForOne,
        uint64 observedAt,
        uint32 rollingVolatilityBps,
        uint32 priceDeviationBps,
        uint32 slippageBps,
        uint32 liquidityImbalanceBps,
        uint128 rollingVolume
    ) internal view returns (RiskComponents memory components) {
        components.volatility = _component(
            rollingVolatilityBps, riskConfig.volatilityThresholdBps, VOLATILITY_WEIGHT_BPS
        );
        components.priceDeviation = _component(
            priceDeviationBps, riskConfig.priceDeviationThresholdBps, PRICE_WEIGHT_BPS
        );
        components.slippage = _component(slippageBps, riskConfig.slippageThresholdBps, SLIPPAGE_WEIGHT_BPS);
        components.liquidityImbalance = _component(
            liquidityImbalanceBps, riskConfig.imbalanceThresholdBps, IMBALANCE_WEIGHT_BPS
        );

        uint32 volumeSpikeBps;
        if (state.lastRollingVolume > 0 && rollingVolume > state.lastRollingVolume) {
            volumeSpikeBps = _toBps(rollingVolume - state.lastRollingVolume, state.lastRollingVolume);
        }
        components.volumeSpike = _component(volumeSpikeBps, riskConfig.volumeSpikeThresholdBps, VOLUME_WEIGHT_BPS);

        bool temporalCorrelation =
            state.lastObservedAt > 0 && observedAt > state.lastObservedAt
                && observedAt - state.lastObservedAt <= riskConfig.temporalWindowSeconds;

        if (
            temporalCorrelation
                && (
                    priceDeviationBps >= (riskConfig.priceDeviationThresholdBps / 2)
                        || slippageBps >= (riskConfig.slippageThresholdBps / 2)
                )
        ) {
            components.temporalCorrelation = TEMPORAL_WEIGHT_BPS;
        }

        if (
            temporalCorrelation && state.lastDirectionZeroForOne != zeroForOne
                && slippageBps >= (riskConfig.slippageThresholdBps / 2)
                && liquidityImbalanceBps >= (riskConfig.imbalanceThresholdBps / 2)
        ) {
            components.mevHeuristic = MEV_WEIGHT_BPS;
        }
    }

    function _sumComponents(RiskComponents memory components) internal pure returns (uint16 score) {
        uint256 total = uint256(components.volatility) + uint256(components.priceDeviation) + uint256(components.slippage)
            + uint256(components.liquidityImbalance) + uint256(components.volumeSpike)
            + uint256(components.temporalCorrelation) + uint256(components.mevHeuristic);

        if (total > BPS) {
            return BPS;
        }
        return uint16(total);
    }

    function _buildMitigationPayload(uint16 riskScoreBps, uint128 rollingVolume, RiskComponents memory components)
        internal
        view
        returns (MitigationPayload memory payload, bytes32 reason)
    {
        bool critical = riskScoreBps >= riskConfig.criticalRiskScoreBps;
        bool mevSensitive = components.mevHeuristic > 0 || components.volumeSpike > 0;

        payload.riskScoreBps = riskScoreBps;
        payload.reason = critical ? REASON_CRITICAL_RISK : REASON_ELEVATED_RISK;
        reason = payload.reason;

        if (critical) {
            payload.mode = MitigationMode.COMBINED;
            payload.dynamicFeePips = riskConfig.criticalDynamicFeePips;
            payload.throttleBps = riskConfig.criticalThrottleBps;
            payload.maxTradeSize = _maxTradeSize(rollingVolume, riskConfig.criticalThrottleBps);
            payload.pauseSeconds = riskConfig.criticalPauseSeconds;
            return (payload, reason);
        }

        payload.dynamicFeePips = riskConfig.highDynamicFeePips;

        if (mevSensitive) {
            payload.mode = MitigationMode.COMBINED;
            payload.throttleBps = riskConfig.highThrottleBps;
            payload.maxTradeSize = _maxTradeSize(rollingVolume, riskConfig.highThrottleBps);
            payload.pauseSeconds = riskConfig.highPauseSeconds;
            return (payload, reason);
        }

        payload.mode = MitigationMode.ADAPTIVE_FEE;
        return (payload, reason);
    }

    function _maxTradeSize(uint128 rollingVolume, uint16 throttleBps) internal pure returns (uint128) {
        if (rollingVolume == 0 || throttleBps == 0) {
            return 0;
        }

        uint256 maxSize = (uint256(rollingVolume) * throttleBps) / BPS;
        if (maxSize == 0) {
            return 1;
        }
        if (maxSize > type(uint128).max) {
            return type(uint128).max;
        }
        return uint128(maxSize);
    }

    function _component(uint32 observedBps, uint32 thresholdBps, uint16 weightBps) internal pure returns (uint16) {
        if (thresholdBps == 0 || observedBps == 0 || weightBps == 0) {
            return 0;
        }

        uint256 observed = observedBps;
        uint256 threshold = thresholdBps;

        if (observed <= threshold) {
            return uint16((observed * weightBps) / (2 * threshold));
        }

        if (observed >= threshold * 2) {
            return weightBps;
        }

        uint256 excess = observed - threshold;
        uint256 additional = (excess * weightBps) / (2 * threshold);
        return uint16((weightBps / 2) + additional);
    }

    function _toBps(uint128 numerator, uint128 denominator) internal pure returns (uint32) {
        if (numerator == 0 || denominator == 0) {
            return 0;
        }

        uint256 value = (uint256(numerator) * BPS) / uint256(denominator);
        if (value > type(uint32).max) {
            return type(uint32).max;
        }
        return uint32(value);
    }

    function _validateRiskConfig(RiskConfig calldata config) internal pure {
        if (
            config.volatilityThresholdBps == 0 || config.priceDeviationThresholdBps == 0
                || config.slippageThresholdBps == 0 || config.imbalanceThresholdBps == 0
                || config.volumeSpikeThresholdBps == 0 || config.highRiskScoreBps == 0
                || config.criticalRiskScoreBps == 0 || config.highRiskScoreBps >= config.criticalRiskScoreBps
                || config.criticalRiskScoreBps > BPS || config.highThrottleBps > BPS || config.criticalThrottleBps > BPS
                || config.highDynamicFeePips > 1_000_000 || config.criticalDynamicFeePips > 1_000_000
                || config.highPauseSeconds == 0 || config.criticalPauseSeconds == 0 || config.temporalWindowSeconds == 0
                || config.mitigationCooldownSeconds == 0
        ) {
            revert SecurityReactive__InvalidRiskConfig();
        }
    }

    function _defaultRiskConfig() internal pure returns (RiskConfig memory config) {
        config = RiskConfig({
            volatilityThresholdBps: 350,
            priceDeviationThresholdBps: 120,
            slippageThresholdBps: 150,
            imbalanceThresholdBps: 2_000,
            volumeSpikeThresholdBps: 1_200,
            highRiskScoreBps: 6_000,
            criticalRiskScoreBps: 8_500,
            highDynamicFeePips: 12_000,
            criticalDynamicFeePips: 60_000,
            highThrottleBps: 3_500,
            criticalThrottleBps: 1_500,
            highPauseSeconds: 60,
            criticalPauseSeconds: 300,
            temporalWindowSeconds: 15,
            mitigationCooldownSeconds: 30
        });
    }
}
