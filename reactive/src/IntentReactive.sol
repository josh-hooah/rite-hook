// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {AbstractReactive, IReactive} from "./lib/ReactiveBase.sol";

contract IntentReactive is AbstractReactive {
    error NotOwner();
    error InvalidConfig();
    error InvalidRetryInterval();

    event IntentTracked(bytes32 indexed intentId, bytes32 indexed poolId, uint256 indexed nonce);
    event IntentDeactivated(bytes32 indexed intentId, bytes32 reason);
    event CallbackQueued(bytes32 indexed intentId, uint256 indexed nonce, bytes32 indexed poolId);
    event DispatchRetryIntervalUpdated(uint64 dispatchRetryInterval);

    uint8 internal constant TRIGGER_PRICE = 0;
    uint8 internal constant TRIGGER_TIME = 1;
    uint8 internal constant TRIGGER_VOLATILITY = 2;

    bytes32 internal constant REASON_CANCELLED = keccak256("CANCELLED");
    bytes32 internal constant REASON_EXECUTED = keccak256("EXECUTED");

    uint256 internal constant INTENT_CREATED_TOPIC_0 =
        uint256(
            keccak256(
                "IntentCreated(bytes32,address,bytes32,uint8,bytes,uint64,uint256,bool,uint256,uint256)"
            )
        );
    uint256 internal constant INTENT_CANCELLED_TOPIC_0 = uint256(keccak256("IntentCancelled(bytes32,address,bytes32,uint256)"));
    uint256 internal constant INTENT_EXECUTED_TOPIC_0 =
        uint256(keccak256("IntentExecuted(bytes32,uint256,uint256,uint256,bool)"));
    uint256 internal constant SWAP_TELEMETRY_TOPIC_0 =
        uint256(keccak256("SwapTelemetry(bytes32,address,int24,uint160,uint32,int128,int128,uint64)"));

    struct ReactiveIntent {
        bytes32 poolId;
        uint8 triggerType;
        uint160 targetSqrtPriceX96;
        bool priceAbove;
        uint64 startTime;
        uint64 endTime;
        uint64 interval;
        uint32 volatilityBps;
        bool volatilityAbove;
        uint16 chunkBips;
        uint64 expiry;
        uint256 nonce;
        uint64 lastTriggeredAt;
        bool active;
    }

    struct ExecutionContext {
        uint160 observedSqrtPriceX96;
        int24 observedTick;
        uint32 observedVolatilityBps;
        uint256 maxAmountIn;
        bytes hookData;
    }

    struct TriggerConfigDecoded {
        uint160 targetSqrtPriceX96;
        bool priceAbove;
        uint64 startTime;
        uint64 endTime;
        uint64 interval;
        uint32 volatilityBps;
        bool volatilityAbove;
        uint16 chunkBips;
    }

    address public owner;
    uint256 public immutable originChainId;
    uint256 public immutable destinationChainId;
    address public immutable hookContract;
    address public immutable executorContract;

    uint64 public callbackGasLimit;
    uint64 public dispatchRetryInterval;

    mapping(bytes32 => ReactiveIntent) public trackedIntents;
    mapping(bytes32 => bytes32[]) public intentsByPool;
    mapping(bytes32 => bool) public processedLogs;
    mapping(bytes32 => uint256) public lastDispatchedNonce;

    constructor(
        address owner_,
        uint256 originChainId_,
        uint256 destinationChainId_,
        address hookContract_,
        address executorContract_,
        uint64 callbackGasLimit_
    ) payable {
        if (owner_ == address(0) || hookContract_ == address(0) || executorContract_ == address(0) || callbackGasLimit_ == 0)
        {
            revert InvalidConfig();
        }

        owner = owner_;
        originChainId = originChainId_;
        destinationChainId = destinationChainId_;
        hookContract = hookContract_;
        executorContract = executorContract_;
        callbackGasLimit = callbackGasLimit_;
        dispatchRetryInterval = 30;

        if (!vm) {
            service.subscribe(originChainId, executorContract, INTENT_CREATED_TOPIC_0, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE);
            service.subscribe(originChainId, executorContract, INTENT_CANCELLED_TOPIC_0, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE);
            service.subscribe(originChainId, executorContract, INTENT_EXECUTED_TOPIC_0, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE);
            service.subscribe(originChainId, hookContract, SWAP_TELEMETRY_TOPIC_0, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE);
        }
    }

    modifier onlyOwner() {
        if (msg.sender != owner) {
            revert NotOwner();
        }
        _;
    }

    function setCallbackGasLimit(uint64 callbackGasLimit_) external onlyOwner {
        if (callbackGasLimit_ == 0) {
            revert InvalidConfig();
        }
        callbackGasLimit = callbackGasLimit_;
    }

    function setDispatchRetryInterval(uint64 dispatchRetryInterval_) external onlyOwner {
        if (dispatchRetryInterval_ == 0) {
            revert InvalidRetryInterval();
        }
        dispatchRetryInterval = dispatchRetryInterval_;
        emit DispatchRetryIntervalUpdated(dispatchRetryInterval_);
    }

    function react(LogRecord calldata log) external vmOnly {
        bytes32 logKey = keccak256(abi.encode(log.chain_id, log.tx_hash, log.log_index));
        if (processedLogs[logKey]) {
            return;
        }
        processedLogs[logKey] = true;

        if (log.topic_0 == INTENT_CREATED_TOPIC_0) {
            if (log._contract != executorContract) {
                return;
            }
            _onIntentCreated(log);
            return;
        }

        if (log.topic_0 == INTENT_CANCELLED_TOPIC_0) {
            if (log._contract != executorContract) {
                return;
            }
            _onIntentCancelled(log);
            return;
        }

        if (log.topic_0 == INTENT_EXECUTED_TOPIC_0) {
            if (log._contract != executorContract) {
                return;
            }
            _onIntentExecuted(log);
            return;
        }

        if (log.topic_0 == SWAP_TELEMETRY_TOPIC_0) {
            if (log._contract != hookContract) {
                return;
            }
            _onSwapTelemetry(log);
        }
    }

    function _onIntentCreated(LogRecord calldata log) internal {
        bytes32 intentId = bytes32(log.topic_1);
        bytes32 poolId = bytes32(log.topic_3);

        (
            uint8 triggerType,
            bytes memory triggerConfigEncoded,
            uint64 expiry,
            uint256 nonce,
            bool zeroForOneIgnored,
            uint256 amountInIgnored,
            uint256 amountOutMinIgnored
        ) = abi.decode(log.data, (uint8, bytes, uint64, uint256, bool, uint256, uint256));
        zeroForOneIgnored;
        amountInIgnored;
        amountOutMinIgnored;

        TriggerConfigDecoded memory trigger = abi.decode(triggerConfigEncoded, (TriggerConfigDecoded));

        ReactiveIntent storage intent = trackedIntents[intentId];
        intent.poolId = poolId;
        intent.triggerType = triggerType;
        intent.targetSqrtPriceX96 = trigger.targetSqrtPriceX96;
        intent.priceAbove = trigger.priceAbove;
        intent.startTime = trigger.startTime;
        intent.endTime = trigger.endTime;
        intent.interval = trigger.interval;
        intent.volatilityBps = trigger.volatilityBps;
        intent.volatilityAbove = trigger.volatilityAbove;
        intent.chunkBips = trigger.chunkBips;
        intent.expiry = expiry;
        intent.nonce = nonce;
        intent.active = true;

        intentsByPool[poolId].push(intentId);

        emit IntentTracked(intentId, poolId, nonce);
    }

    function _onIntentCancelled(LogRecord calldata log) internal {
        bytes32 intentId = bytes32(log.topic_1);
        ReactiveIntent storage intent = trackedIntents[intentId];
        if (!intent.active) {
            return;
        }

        intent.active = false;
        emit IntentDeactivated(intentId, REASON_CANCELLED);
    }

    function _onIntentExecuted(LogRecord calldata log) internal {
        bytes32 intentId = bytes32(log.topic_1);
        uint256 nonce = log.topic_2;

        ReactiveIntent storage intent = trackedIntents[intentId];
        if (!intent.active) {
            return;
        }

        (uint256 executedAmountIgnored, uint256 outputAmountIgnored, bool fullyExecuted) =
            abi.decode(log.data, (uint256, uint256, bool));
        executedAmountIgnored;
        outputAmountIgnored;

        if (fullyExecuted) {
            intent.active = false;
            emit IntentDeactivated(intentId, REASON_EXECUTED);
            return;
        }

        uint256 nextNonce = nonce + 1;
        if (nextNonce > intent.nonce) {
            intent.nonce = nextNonce;
        }
    }

    function _onSwapTelemetry(LogRecord calldata log) internal {
        bytes32 poolId = bytes32(log.topic_1);

        (
            int24 tick,
            uint160 sqrtPriceX96,
            uint32 rollingVolatilityBps,
            int128 amount0DeltaIgnored,
            int128 amount1DeltaIgnored,
            uint64 observedAt
        ) =
            abi.decode(log.data, (int24, uint160, uint32, int128, int128, uint64));
        amount0DeltaIgnored;
        amount1DeltaIgnored;

        bytes32[] storage poolIntentIds = intentsByPool[poolId];
        for (uint256 i = 0; i < poolIntentIds.length; i++) {
            bytes32 intentId = poolIntentIds[i];
            ReactiveIntent storage intent = trackedIntents[intentId];
            if (!intent.active) {
                continue;
            }
            if (
                intent.lastTriggeredAt != 0
                    &&
                lastDispatchedNonce[intentId] == intent.nonce
                    && observedAt <= uint256(intent.lastTriggeredAt) + dispatchRetryInterval
            ) {
                continue;
            }
            if (observedAt > intent.expiry) {
                continue;
            }

            bool shouldTrigger = _shouldTrigger(intent, sqrtPriceX96, rollingVolatilityBps, observedAt);
            if (!shouldTrigger) {
                continue;
            }

            bytes memory context = abi.encode(
                ExecutionContext({
                    observedSqrtPriceX96: sqrtPriceX96,
                    observedTick: tick,
                    observedVolatilityBps: rollingVolatilityBps,
                    maxAmountIn: 0,
                    hookData: bytes("")
                })
            );

            bytes memory payload = abi.encodeWithSignature(
                "executeIntent(address,bytes32,uint256,bytes)", address(0), intentId, intent.nonce, context
            );

            emit Callback(destinationChainId, executorContract, callbackGasLimit, payload);
            emit CallbackQueued(intentId, intent.nonce, poolId);

            lastDispatchedNonce[intentId] = intent.nonce;
            intent.lastTriggeredAt = observedAt;
        }
    }

    function _shouldTrigger(ReactiveIntent storage intent, uint160 sqrtPriceX96, uint32 rollingVolatilityBps, uint64 observedAt)
        internal
        view
        returns (bool)
    {
        if (intent.triggerType == TRIGGER_PRICE) {
            if (intent.targetSqrtPriceX96 == 0) {
                return false;
            }
            return intent.priceAbove ? sqrtPriceX96 >= intent.targetSqrtPriceX96 : sqrtPriceX96 <= intent.targetSqrtPriceX96;
        }

        if (intent.triggerType == TRIGGER_TIME) {
            if (observedAt < intent.startTime) {
                return false;
            }
            if (intent.endTime != 0 && observedAt > intent.endTime) {
                return false;
            }
            if (intent.interval > 0 && intent.lastTriggeredAt > 0 && observedAt < uint256(intent.lastTriggeredAt) + intent.interval)
            {
                return false;
            }
            return true;
        }

        if (intent.volatilityBps == 0) {
            return false;
        }
        return intent.volatilityAbove ? rollingVolatilityBps >= intent.volatilityBps : rollingVolatilityBps <= intent.volatilityBps;
    }
}
