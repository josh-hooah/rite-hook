// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {IntentExecutor} from "../../src/IntentExecutor.sol";
import {TriggerType, IntentStatus, TriggerConfig, IntentParams, Intent, ExecutionContext} from "../../src/libraries/IntentTypes.sol";
import {IIntentSwapAdapter} from "../../src/interfaces/IIntentSwapAdapter.sol";

import {MockSwapAdapter} from "../mocks/MockSwapAdapter.sol";

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";

contract IntentExecutorInvariantHandler is Test {
    IntentExecutor internal immutable executor;
    MockSwapAdapter internal immutable adapter;
    MockERC20 internal immutable token0;
    MockERC20 internal immutable token1;
    PoolKey internal poolKey;
    address internal immutable callbackProxy;
    address internal immutable reactVM;

    bytes32[] internal intentIds;

    constructor(
        IntentExecutor executor_,
        MockSwapAdapter adapter_,
        MockERC20 token0_,
        MockERC20 token1_,
        PoolKey memory poolKey_,
        address callbackProxy_,
        address reactVM_
    ) {
        executor = executor_;
        adapter = adapter_;
        token0 = token0_;
        token1 = token1_;
        poolKey = poolKey_;
        callbackProxy = callbackProxy_;
        reactVM = reactVM_;

        token0.approve(address(executor_), type(uint256).max);
    }

    function intentCount() external view returns (uint256) {
        return intentIds.length;
    }

    function intentIdAt(uint256 index) external view returns (bytes32) {
        return intentIds[index];
    }

    function createPriceIntent(uint96 rawAmount, uint32 expiryOffset, bool priceAbove, uint160 targetRaw) external {
        if (intentIds.length >= 32) {
            return;
        }

        uint256 amount = bound(uint256(rawAmount), 1 ether, 1_000 ether);
        uint64 expiry = uint64(block.timestamp + bound(uint256(expiryOffset), 1 hours, 7 days));
        uint160 target = uint160(bound(uint256(targetRaw), 1, type(uint160).max));

        TriggerConfig memory trigger = TriggerConfig({
            targetSqrtPriceX96: target,
            priceAbove: priceAbove,
            startTime: 0,
            endTime: 0,
            interval: 0,
            volatilityBps: 0,
            volatilityAbove: false,
            chunkBips: 10_000
        });

        IntentParams memory params = IntentParams({
            poolKey: poolKey,
            tokenIn: address(token0),
            tokenOut: address(token1),
            zeroForOne: true,
            amountIn: amount,
            amountOutMin: amount,
            triggerType: TriggerType.PRICE,
            trigger: trigger,
            expiry: expiry
        });

        try executor.createIntent(params) returns (bytes32 intentId) {
            intentIds.push(intentId);
        } catch {}
    }

    function createTimeIntent(uint96 rawAmount, uint32 startDelay, uint32 interval, uint16 rawChunkBips) external {
        if (intentIds.length >= 32) {
            return;
        }

        uint256 amount = bound(uint256(rawAmount), 1 ether, 1_000 ether);
        uint64 expiry = uint64(block.timestamp + 7 days);
        uint16 chunkBips = uint16(bound(uint256(rawChunkBips), 1, 10_000));
        uint64 startTime = uint64(block.timestamp + bound(uint256(startDelay), 1, 1 days));
        uint64 cadence = uint64(bound(uint256(interval), 0, 1 days));

        TriggerConfig memory trigger = TriggerConfig({
            targetSqrtPriceX96: 0,
            priceAbove: false,
            startTime: startTime,
            endTime: 0,
            interval: cadence,
            volatilityBps: 0,
            volatilityAbove: false,
            chunkBips: chunkBips
        });

        IntentParams memory params = IntentParams({
            poolKey: poolKey,
            tokenIn: address(token0),
            tokenOut: address(token1),
            zeroForOne: true,
            amountIn: amount,
            amountOutMin: amount,
            triggerType: TriggerType.TIME,
            trigger: trigger,
            expiry: expiry
        });

        try executor.createIntent(params) returns (bytes32 intentId) {
            intentIds.push(intentId);
        } catch {}
    }

    function createVolIntent(uint96 rawAmount, uint32 expiryOffset, uint32 rawVolatility, bool above) external {
        if (intentIds.length >= 32) {
            return;
        }

        uint256 amount = bound(uint256(rawAmount), 1 ether, 1_000 ether);
        uint64 expiry = uint64(block.timestamp + bound(uint256(expiryOffset), 1 hours, 7 days));
        uint32 volatilityBps = uint32(bound(uint256(rawVolatility), 1, type(uint32).max));

        TriggerConfig memory trigger = TriggerConfig({
            targetSqrtPriceX96: 0,
            priceAbove: false,
            startTime: 0,
            endTime: 0,
            interval: 0,
            volatilityBps: volatilityBps,
            volatilityAbove: above,
            chunkBips: 10_000
        });

        IntentParams memory params = IntentParams({
            poolKey: poolKey,
            tokenIn: address(token0),
            tokenOut: address(token1),
            zeroForOne: true,
            amountIn: amount,
            amountOutMin: amount,
            triggerType: TriggerType.VOLATILITY,
            trigger: trigger,
            expiry: expiry
        });

        try executor.createIntent(params) returns (bytes32 intentId) {
            intentIds.push(intentId);
        } catch {}
    }

    function cancelIntent(uint256 rawIndex) external {
        if (intentIds.length == 0) {
            return;
        }
        uint256 index = bound(rawIndex, 0, intentIds.length - 1);
        try executor.cancelIntent(intentIds[index]) {} catch {}
    }

    function updateIntent(uint256 rawIndex, uint96 rawMinOut, uint32 expiryOffset, uint16 rawChunkBips, uint160 targetRaw)
        external
    {
        if (intentIds.length == 0) {
            return;
        }

        uint256 index = bound(rawIndex, 0, intentIds.length - 1);
        bytes32 intentId = intentIds[index];
        Intent memory intent = executor.getIntent(intentId);
        if (intent.status != IntentStatus.PENDING) {
            return;
        }

        uint256 minOut = bound(uint256(rawMinOut), 1, intent.amountIn * 10);
        uint64 expiry = uint64(block.timestamp + bound(uint256(expiryOffset), 1 hours, 7 days));
        uint16 chunkBips = uint16(bound(uint256(rawChunkBips), 1, 10_000));

        TriggerConfig memory next = TriggerConfig({
            targetSqrtPriceX96: uint160(bound(uint256(targetRaw), 1, type(uint160).max)),
            priceAbove: true,
            startTime: 0,
            endTime: 0,
            interval: 0,
            volatilityBps: 0,
            volatilityAbove: false,
            chunkBips: chunkBips
        });

        try executor.updateIntent(intentId, minOut, expiry, next) {} catch {}
    }

    function executeIntent(uint256 rawIndex, uint32 mode, uint160 observedPriceRaw, uint32 observedVolRaw, uint96 maxAmountInRaw)
        external
    {
        if (intentIds.length == 0) {
            return;
        }

        uint256 index = bound(rawIndex, 0, intentIds.length - 1);
        bytes32 intentId = intentIds[index];
        Intent memory intent = executor.getIntent(intentId);
        if (intent.status != IntentStatus.PENDING) {
            return;
        }

        uint256 nonce;
        if (mode % 3 == 0) {
            nonce = intent.nonce;
        } else if (mode % 3 == 1) {
            nonce = intent.nonce + 1;
        } else {
            nonce = 0;
        }

        ExecutionContext memory context = ExecutionContext({
            observedSqrtPriceX96: uint160(bound(uint256(observedPriceRaw), 1, type(uint160).max)),
            observedTick: 0,
            observedVolatilityBps: uint32(bound(uint256(observedVolRaw), 1, type(uint32).max)),
            maxAmountIn: bound(uint256(maxAmountInRaw), 0, 1_000 ether),
            hookData: bytes("")
        });

        address vmId = mode % 5 == 0 ? address(0xDEAD) : reactVM;
        if (mode % 2 == 0) {
            vm.prank(callbackProxy);
            try executor.executeIntent(vmId, intentId, nonce, abi.encode(context)) {} catch {}
            return;
        }

        try executor.executeIntent(vmId, intentId, nonce, abi.encode(context)) {} catch {}
    }

    function configureAdapter(bool shouldRevert, uint96 amountOut) external {
        adapter.setRevert(shouldRevert);
        adapter.setAmountOut(uint256(bound(uint256(amountOut), 1, 5_000 ether)));
    }

    function warpForward(uint32 bySeconds) external {
        vm.warp(block.timestamp + bound(uint256(bySeconds), 0, 30 days));
    }
}

contract IntentExecutorInvariantTest is StdInvariant, Test {
    IntentExecutor internal executor;
    MockSwapAdapter internal adapter;
    MockERC20 internal token0;
    MockERC20 internal token1;
    IntentExecutorInvariantHandler internal handler;

    PoolKey internal poolKey;

    address internal constant CALLBACK_PROXY = address(0xCA11BACC);
    address internal constant REACT_VM = address(0xBEEF);

    function setUp() public {
        token0 = new MockERC20("Token0", "TK0", 18);
        token1 = new MockERC20("Token1", "TK1", 18);
        if (address(token0) > address(token1)) {
            (token0, token1) = (token1, token0);
        }

        poolKey = PoolKey({
            currency0: Currency.wrap(address(token0)),
            currency1: Currency.wrap(address(token1)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(0))
        });

        adapter = new MockSwapAdapter();
        adapter.setAmountOut(1_000 ether);

        executor = new IntentExecutor(address(this), CALLBACK_PROXY, IIntentSwapAdapter(address(adapter)));
        executor.setReactVM(REACT_VM, true);

        handler = new IntentExecutorInvariantHandler(executor, adapter, token0, token1, poolKey, CALLBACK_PROXY, REACT_VM);

        token0.mint(address(handler), 1_000_000 ether);
        token1.mint(address(adapter), 1_000_000 ether);

        targetContract(address(handler));
    }

    function invariant_executorCustodyMatchesPendingRemaining() public view {
        uint256 intents = handler.intentCount();
        uint256 pendingRemaining;

        for (uint256 i = 0; i < intents; i++) {
            bytes32 intentId = handler.intentIdAt(i);
            Intent memory intent = executor.getIntent(intentId);

            if (intent.status == IntentStatus.PENDING) {
                pendingRemaining += intent.remainingAmount;
            }
        }

        assertEq(token0.balanceOf(address(executor)), pendingRemaining);
    }

    function invariant_remainingAmountWithinBounds() public view {
        uint256 intents = handler.intentCount();

        for (uint256 i = 0; i < intents; i++) {
            bytes32 intentId = handler.intentIdAt(i);
            Intent memory intent = executor.getIntent(intentId);

            assertLe(intent.remainingAmount, intent.amountIn);

            if (intent.status != IntentStatus.PENDING) {
                assertEq(intent.remainingAmount, 0);
            }

            if (intent.status == IntentStatus.EXECUTED) {
                assertEq(intent.remainingAmount, 0);
                assertGt(intent.nonce, 0);
            }
        }
    }
}
