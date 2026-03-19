// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

import {IIntentSwapAdapter} from "./interfaces/IIntentSwapAdapter.sol";
import {
    TriggerType,
    IntentStatus,
    TriggerConfig,
    IntentParams,
    Intent,
    ExecutionResult,
    ExecutionContext
} from "./libraries/IntentTypes.sol";
import {PriceCondition} from "./libraries/PriceCondition.sol";
import {VolatilityMath} from "./libraries/VolatilityMath.sol";
import {IntentEncoding} from "./libraries/IntentEncoding.sol";
import {ReasonCodes} from "./libraries/ReasonCodes.sol";

contract IntentExecutor is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using PoolIdLibrary for PoolKey;

    error ZeroAddress();
    error InvalidAmount();
    error InvalidExpiry();
    error InvalidTrigger();
    error InvalidDirection();
    error IntentAlreadyExists(bytes32 intentId);
    error IntentNotFound(bytes32 intentId);
    error IntentNotOwned(bytes32 intentId, address caller);
    error UnauthorizedCallbackSender(address caller);
    error UnauthorizedReactVM(address reactVM);
    error SlippageExceeded(uint256 minOut, uint256 actualOut);

    event CallbackProxyUpdated(address indexed callbackProxy);
    event ReactVMAllowlistUpdated(address indexed reactVM, bool allowed);
    event SwapAdapterUpdated(address indexed swapAdapter);

    event IntentCreated(
        bytes32 indexed intentId,
        address indexed user,
        bytes32 indexed poolId,
        uint8 triggerType,
        bytes triggerConfig,
        uint64 expiry,
        uint256 nonce,
        bool zeroForOne,
        uint256 amountIn,
        uint256 amountOutMin
    );
    event IntentUpdated(bytes32 indexed intentId, uint256 amountOutMin, uint64 expiry, uint256 nonce);
    event IntentCancelled(bytes32 indexed intentId, address indexed user, bytes32 indexed poolId, uint256 nonce);
    event IntentExecutable(bytes32 indexed intentId, uint256 indexed nonce, bool executable, bytes32 reason);
    event IntentExecuted(
        bytes32 indexed intentId,
        uint256 indexed nonce,
        uint256 executedAmount,
        uint256 outputAmount,
        bool fullyExecuted
    );
    event ExecutionFailed(bytes32 indexed intentId, uint256 indexed nonce, bytes32 reason);

    address public callbackProxy;
    IIntentSwapAdapter public swapAdapter;

    mapping(address => bool) public reactVMAllowlist;
    mapping(address => uint256) public userIntentCount;
    mapping(bytes32 => Intent) private _intents;
    mapping(bytes32 => ExecutionResult) public lastExecution;

    constructor(address initialOwner, address callbackProxy_, IIntentSwapAdapter swapAdapter_) Ownable(initialOwner) {
        if (callbackProxy_ == address(0) || address(swapAdapter_) == address(0)) {
            revert ZeroAddress();
        }
        callbackProxy = callbackProxy_;
        swapAdapter = swapAdapter_;
    }

    function setCallbackProxy(address callbackProxy_) external onlyOwner {
        if (callbackProxy_ == address(0)) {
            revert ZeroAddress();
        }
        callbackProxy = callbackProxy_;
        emit CallbackProxyUpdated(callbackProxy_);
    }

    function setReactVM(address reactVM, bool allowed) external onlyOwner {
        if (reactVM == address(0)) {
            revert ZeroAddress();
        }
        reactVMAllowlist[reactVM] = allowed;
        emit ReactVMAllowlistUpdated(reactVM, allowed);
    }

    function setSwapAdapter(IIntentSwapAdapter swapAdapter_) external onlyOwner {
        if (address(swapAdapter_) == address(0)) {
            revert ZeroAddress();
        }
        swapAdapter = swapAdapter_;
        emit SwapAdapterUpdated(address(swapAdapter_));
    }

    function getIntent(bytes32 intentId) external view returns (Intent memory) {
        return _intents[intentId];
    }

    function createIntent(IntentParams calldata params) external nonReentrant returns (bytes32 intentId) {
        _validateIntentParams(params);

        uint16 chunkBips = params.trigger.chunkBips == 0 ? uint16(10_000) : params.trigger.chunkBips;

        uint256 ordinal = userIntentCount[msg.sender]++;
        bytes32 poolId = PoolId.unwrap(params.poolKey.toId());
        intentId = keccak256(
            abi.encode(msg.sender, ordinal, poolId, params.tokenIn, params.tokenOut, params.amountIn, block.chainid)
        );

        if (_intents[intentId].status != IntentStatus.NONE) {
            revert IntentAlreadyExists(intentId);
        }

        TriggerConfig memory trigger = params.trigger;
        trigger.chunkBips = chunkBips;

        Intent storage intent = _intents[intentId];
        intent.intentId = intentId;
        intent.user = msg.sender;
        intent.poolId = poolId;
        intent.poolKey = params.poolKey;
        intent.tokenIn = params.tokenIn;
        intent.tokenOut = params.tokenOut;
        intent.zeroForOne = params.zeroForOne;
        intent.amountIn = params.amountIn;
        intent.amountOutMin = params.amountOutMin;
        intent.triggerType = params.triggerType;
        intent.trigger = trigger;
        intent.expiry = params.expiry;
        intent.createdAt = uint64(block.timestamp);
        intent.lastExecutionAt = 0;
        intent.nonce = 0;
        intent.remainingAmount = params.amountIn;
        intent.status = IntentStatus.PENDING;

        IERC20(params.tokenIn).safeTransferFrom(msg.sender, address(this), params.amountIn);

        _emitIntentCreated(intent);
    }

    function updateIntent(bytes32 intentId, uint256 amountOutMin, uint64 expiry, TriggerConfig calldata trigger)
        external
        nonReentrant
    {
        Intent storage intent = _intents[intentId];
        _requireIntentOwner(intentId, intent);

        if (intent.status != IntentStatus.PENDING) {
            revert InvalidTrigger();
        }
        if (amountOutMin == 0 || amountOutMin > intent.amountIn * 10) {
            revert InvalidAmount();
        }
        if (expiry <= block.timestamp) {
            revert InvalidExpiry();
        }
        _validateTriggerConfig(intent.triggerType, trigger);

        intent.amountOutMin = amountOutMin;
        intent.expiry = expiry;
        intent.trigger = trigger;
        if (intent.trigger.chunkBips == 0) {
            intent.trigger.chunkBips = 10_000;
        }

        emit IntentUpdated(intentId, amountOutMin, expiry, intent.nonce);
    }

    function cancelIntent(bytes32 intentId) external nonReentrant {
        Intent storage intent = _intents[intentId];
        _requireIntentOwner(intentId, intent);

        if (intent.status != IntentStatus.PENDING) {
            return;
        }

        intent.status = IntentStatus.CANCELLED;

        if (intent.remainingAmount > 0) {
            IERC20(intent.tokenIn).safeTransfer(intent.user, intent.remainingAmount);
            intent.remainingAmount = 0;
        }

        emit IntentCancelled(intentId, intent.user, intent.poolId, intent.nonce);
    }

    /// @notice Destination callback invoked via Callback Proxy with reactVM as first argument.
    function executeIntent(address reactVM, bytes32 intentId, uint256 nonce, bytes calldata extra)
        external
        nonReentrant
        returns (bool)
    {
        if (msg.sender != callbackProxy) {
            revert UnauthorizedCallbackSender(msg.sender);
        }
        if (!reactVMAllowlist[reactVM]) {
            revert UnauthorizedReactVM(reactVM);
        }

        Intent storage intent = _intents[intentId];
        if (intent.status != IntentStatus.PENDING) {
            emit IntentExecutable(intentId, nonce, false, ReasonCodes.INTENT_INACTIVE);
            return false;
        }

        if (nonce != intent.nonce) {
            emit IntentExecutable(intentId, nonce, false, ReasonCodes.NONCE_MISMATCH);
            return false;
        }

        if (block.timestamp > intent.expiry) {
            _markExpiredAndRefund(intentId, intent, nonce);
            return false;
        }

        ExecutionContext memory context = IntentEncoding.decodeExecutionContext(extra);

        if (!_isContextValid(intent, context)) {
            emit IntentExecutable(intentId, nonce, false, ReasonCodes.INVALID_CONTEXT);
            return false;
        }

        if (!_isTriggerSatisfied(intent, context)) {
            emit IntentExecutable(intentId, nonce, false, ReasonCodes.TRIGGER_NOT_MET);
            return false;
        }

        emit IntentExecutable(intentId, nonce, true, ReasonCodes.OK);

        uint256 executionAmount = _computeExecutionAmount(intent, context.maxAmountIn);
        if (executionAmount == 0 || executionAmount > intent.remainingAmount) {
            emit ExecutionFailed(intentId, nonce, ReasonCodes.INVALID_CONTEXT);
            return false;
        }

        uint256 minOutForSlice = (intent.amountOutMin * executionAmount) / intent.amountIn;
        if (minOutForSlice == 0) {
            minOutForSlice = 1;
        }

        IERC20(intent.tokenIn).forceApprove(address(swapAdapter), executionAmount);

        uint256 outputAmount;
        try swapAdapter.executeSwap(
            IIntentSwapAdapter.SwapRequest({
                intentId: intentId,
                tokenIn: intent.tokenIn,
                tokenOut: intent.tokenOut,
                poolKey: intent.poolKey,
                zeroForOne: intent.zeroForOne,
                amountIn: executionAmount,
                amountOutMin: minOutForSlice,
                hookData: context.hookData,
                recipient: address(this),
                deadline: block.timestamp + 600
            })
        ) returns (uint256 amountOut) {
            outputAmount = amountOut;
        } catch {
            lastExecution[intentId] = ExecutionResult({
                executedAt: uint64(block.timestamp),
                executedAmount: executionAmount,
                outputAmount: 0,
                reason: ReasonCodes.ADAPTER_REVERT
            });
            emit ExecutionFailed(intentId, nonce, ReasonCodes.ADAPTER_REVERT);
            return false;
        }

        if (outputAmount < minOutForSlice) {
            revert SlippageExceeded(minOutForSlice, outputAmount);
        }

        IERC20(intent.tokenOut).safeTransfer(intent.user, outputAmount);

        intent.remainingAmount -= executionAmount;
        intent.lastExecutionAt = uint64(block.timestamp);
        intent.nonce += 1;

        bool fullyExecuted = intent.remainingAmount == 0;
        if (fullyExecuted) {
            intent.status = IntentStatus.EXECUTED;
        }

        lastExecution[intentId] = ExecutionResult({
            executedAt: uint64(block.timestamp),
            executedAmount: executionAmount,
            outputAmount: outputAmount,
            reason: ReasonCodes.OK
        });

        return _emitIntentExecuted(intentId, nonce, executionAmount, outputAmount, fullyExecuted);
    }

    function _emitIntentExecuted(
        bytes32 intentId,
        uint256 nonce,
        uint256 executionAmount,
        uint256 outputAmount,
        bool fullyExecuted
    ) internal returns (bool) {
        emit IntentExecuted(intentId, nonce, executionAmount, outputAmount, fullyExecuted);
        return true;
    }

    function _markExpiredAndRefund(bytes32 intentId, Intent storage intent, uint256 nonce) internal {
        intent.status = IntentStatus.EXPIRED;

        if (intent.remainingAmount > 0) {
            IERC20(intent.tokenIn).safeTransfer(intent.user, intent.remainingAmount);
            intent.remainingAmount = 0;
        }

        lastExecution[intentId] = ExecutionResult({
            executedAt: uint64(block.timestamp),
            executedAmount: 0,
            outputAmount: 0,
            reason: ReasonCodes.EXPIRED
        });

        emit ExecutionFailed(intentId, nonce, ReasonCodes.EXPIRED);
    }

    function _computeExecutionAmount(Intent storage intent, uint256 maxAmountIn) internal view returns (uint256) {
        uint256 executionAmount;

        if (intent.triggerType == TriggerType.TIME) {
            executionAmount = (intent.amountIn * intent.trigger.chunkBips) / 10_000;
            if (executionAmount == 0) {
                executionAmount = 1;
            }
            if (executionAmount > intent.remainingAmount) {
                executionAmount = intent.remainingAmount;
            }
        } else {
            executionAmount = intent.remainingAmount;
        }

        if (maxAmountIn > 0 && maxAmountIn < executionAmount) {
            executionAmount = maxAmountIn;
        }

        return executionAmount;
    }

    function _isContextValid(Intent storage intent, ExecutionContext memory context) internal view returns (bool) {
        if (intent.triggerType == TriggerType.PRICE) {
            return context.observedSqrtPriceX96 > 0;
        }
        if (intent.triggerType == TriggerType.VOLATILITY) {
            return context.observedVolatilityBps > 0;
        }
        return true;
    }

    function _isTriggerSatisfied(Intent storage intent, ExecutionContext memory context) internal view returns (bool) {
        if (intent.triggerType == TriggerType.PRICE) {
            return PriceCondition.meetsTarget(
                context.observedSqrtPriceX96, intent.trigger.targetSqrtPriceX96, intent.trigger.priceAbove
            );
        }

        if (intent.triggerType == TriggerType.TIME) {
            if (block.timestamp < intent.trigger.startTime) {
                return false;
            }
            if (intent.trigger.endTime != 0 && block.timestamp > intent.trigger.endTime) {
                return false;
            }
            if (
                intent.trigger.interval > 0 && intent.lastExecutionAt > 0
                    && block.timestamp < uint256(intent.lastExecutionAt) + intent.trigger.interval
            ) {
                return false;
            }
            return true;
        }

        return VolatilityMath.meetsThreshold(
            context.observedVolatilityBps, intent.trigger.volatilityBps, intent.trigger.volatilityAbove
        );
    }

    function _validateIntentParams(IntentParams calldata params) internal view {
        if (params.tokenIn == address(0) || params.tokenOut == address(0) || params.tokenIn == params.tokenOut) {
            revert ZeroAddress();
        }
        if (params.amountIn == 0 || params.amountOutMin == 0) {
            revert InvalidAmount();
        }
        if (params.expiry <= block.timestamp) {
            revert InvalidExpiry();
        }

        address currency0 = Currency.unwrap(params.poolKey.currency0);
        address currency1 = Currency.unwrap(params.poolKey.currency1);
        if (params.zeroForOne) {
            if (params.tokenIn != currency0 || params.tokenOut != currency1) {
                revert InvalidDirection();
            }
        } else {
            if (params.tokenIn != currency1 || params.tokenOut != currency0) {
                revert InvalidDirection();
            }
        }

        _validateTriggerConfig(params.triggerType, params.trigger);
    }

    function _validateTriggerConfig(TriggerType triggerType, TriggerConfig calldata trigger) internal pure {
        if (trigger.chunkBips > 10_000) {
            revert InvalidTrigger();
        }

        if (triggerType == TriggerType.PRICE) {
            if (trigger.targetSqrtPriceX96 == 0) {
                revert InvalidTrigger();
            }
            return;
        }

        if (triggerType == TriggerType.TIME) {
            if (trigger.startTime == 0) {
                revert InvalidTrigger();
            }
            if (trigger.endTime != 0 && trigger.endTime < trigger.startTime) {
                revert InvalidTrigger();
            }
            return;
        }

        if (trigger.volatilityBps == 0) {
            revert InvalidTrigger();
        }
    }

    function _requireIntentOwner(bytes32 intentId, Intent storage intent) internal view {
        if (intent.status == IntentStatus.NONE) {
            revert IntentNotFound(intentId);
        }
        if (intent.user != msg.sender) {
            revert IntentNotOwned(intentId, msg.sender);
        }
    }

    function _emitIntentCreated(Intent storage intent) internal {
        emit IntentCreated(
            intent.intentId,
            intent.user,
            intent.poolId,
            uint8(intent.triggerType),
            abi.encode(intent.trigger),
            intent.expiry,
            intent.nonce,
            intent.zeroForOne,
            intent.amountIn,
            intent.amountOutMin
        );
    }
}
