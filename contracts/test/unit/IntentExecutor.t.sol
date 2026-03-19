// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {IntentExecutor} from "../../src/IntentExecutor.sol";
import {TriggerType, IntentStatus, TriggerConfig, IntentParams, Intent, ExecutionContext} from "../../src/libraries/IntentTypes.sol";
import {IIntentSwapAdapter} from "../../src/interfaces/IIntentSwapAdapter.sol";

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";

import {MockSwapAdapter} from "../mocks/MockSwapAdapter.sol";

contract IntentExecutorUnitTest is Test {
    IntentExecutor internal executor;
    MockSwapAdapter internal adapter;

    MockERC20 internal token0;
    MockERC20 internal token1;

    PoolKey internal poolKey;

    address internal constant CALLBACK_PROXY = address(0xCA11BACC);
    address internal constant REACT_VM = address(0xBEEF);
    address internal constant ALICE = address(0xA11CE);

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
        executor = new IntentExecutor(address(this), CALLBACK_PROXY, IIntentSwapAdapter(address(adapter)));
        executor.setReactVM(REACT_VM, true);

        token0.mint(address(this), 1_000_000 ether);
        token0.mint(ALICE, 1_000_000 ether);
        token1.mint(address(this), 1_000_000 ether);
        token1.mint(ALICE, 1_000_000 ether);
        token1.mint(address(adapter), 1_000_000 ether);

        token0.approve(address(executor), type(uint256).max);
        token1.approve(address(executor), type(uint256).max);
        vm.prank(ALICE);
        token0.approve(address(executor), type(uint256).max);
        vm.prank(ALICE);
        token1.approve(address(executor), type(uint256).max);

        adapter.setAmountOut(100 ether);
    }

    function testConstructorRevertsWhenAddressesAreZero() public {
        vm.expectRevert(IntentExecutor.ZeroAddress.selector);
        new IntentExecutor(address(this), address(0), IIntentSwapAdapter(address(adapter)));

        vm.expectRevert(IntentExecutor.ZeroAddress.selector);
        new IntentExecutor(address(this), CALLBACK_PROXY, IIntentSwapAdapter(address(0)));
    }

    function testOwnerSettersValidateInput() public {
        executor.setCallbackProxy(address(0xB0B));
        assertEq(executor.callbackProxy(), address(0xB0B));

        executor.setReactVM(address(0xBEEF1), true);
        assertTrue(executor.reactVMAllowlist(address(0xBEEF1)));
        executor.setReactVM(address(0xBEEF1), false);
        assertFalse(executor.reactVMAllowlist(address(0xBEEF1)));

        MockSwapAdapter replacement = new MockSwapAdapter();
        executor.setSwapAdapter(IIntentSwapAdapter(address(replacement)));
        assertEq(address(executor.swapAdapter()), address(replacement));

        vm.expectRevert(IntentExecutor.ZeroAddress.selector);
        executor.setCallbackProxy(address(0));
        vm.expectRevert(IntentExecutor.ZeroAddress.selector);
        executor.setReactVM(address(0), true);
        vm.expectRevert(IntentExecutor.ZeroAddress.selector);
        executor.setSwapAdapter(IIntentSwapAdapter(address(0)));
    }

    function testCreateIntentStoresIntentAndCustodiesFunds() public {
        uint256 balanceBefore = token0.balanceOf(address(this));

        bytes32 intentId = _createPriceIntent(100 ether, uint64(block.timestamp + 1 days), true);
        Intent memory intent = executor.getIntent(intentId);

        assertEq(uint8(intent.status), uint8(IntentStatus.PENDING));
        assertEq(intent.remainingAmount, 100 ether);
        assertEq(intent.user, address(this));

        assertEq(token0.balanceOf(address(executor)), 100 ether);
        assertEq(token0.balanceOf(address(this)), balanceBefore - 100 ether);
    }

    function testCreateIntentSupportsOneForZeroDirection() public {
        TriggerConfig memory trigger = _priceTrigger(1_000, true, 10_000);
        IntentParams memory params = IntentParams({
            poolKey: poolKey,
            tokenIn: address(token1),
            tokenOut: address(token0),
            zeroForOne: false,
            amountIn: 10 ether,
            amountOutMin: 10 ether,
            triggerType: TriggerType.PRICE,
            trigger: trigger,
            expiry: uint64(block.timestamp + 1 days)
        });

        bytes32 intentId = executor.createIntent(params);
        Intent memory intent = executor.getIntent(intentId);
        assertEq(intent.tokenIn, address(token1));
        assertEq(intent.tokenOut, address(token0));
        assertFalse(intent.zeroForOne);
    }

    function testCreateIntentDefaultsChunkBipsWhenZero() public {
        TriggerConfig memory trigger = TriggerConfig({
            targetSqrtPriceX96: 1_000,
            priceAbove: true,
            startTime: 0,
            endTime: 0,
            interval: 0,
            volatilityBps: 0,
            volatilityAbove: false,
            chunkBips: 0
        });
        IntentParams memory params = _baseParams(TriggerType.PRICE, trigger, 10 ether, 10 ether, uint64(block.timestamp + 1 days));

        bytes32 intentId = executor.createIntent(params);
        Intent memory intent = executor.getIntent(intentId);
        assertEq(intent.trigger.chunkBips, 10_000);
    }

    function testCreateIntentRevertsWhenIntentIdAlreadyExists() public {
        TriggerConfig memory trigger = _priceTrigger(1_000, true, 10_000);
        IntentParams memory params =
            _baseParams(TriggerType.PRICE, trigger, 10 ether, 10 ether, uint64(block.timestamp + 1 days));

        bytes32 intentId = executor.createIntent(params);

        // Force ordinal rewind to recreate the exact same deterministic intentId.
        bytes32 userIntentCountSlot = keccak256(abi.encode(address(this), uint256(5)));
        vm.store(address(executor), userIntentCountSlot, bytes32(0));

        vm.expectRevert(abi.encodeWithSelector(IntentExecutor.IntentAlreadyExists.selector, intentId));
        executor.createIntent(params);
    }

    function testCreateIntentRevertsOnInvalidTokenAddressAndAmount() public {
        TriggerConfig memory trigger = _priceTrigger(1_000, true, 10_000);
        IntentParams memory params =
            _baseParams(TriggerType.PRICE, trigger, 10 ether, 10 ether, uint64(block.timestamp + 1 days));

        params.tokenIn = address(0);
        vm.expectRevert(IntentExecutor.ZeroAddress.selector);
        executor.createIntent(params);

        params = _baseParams(TriggerType.PRICE, trigger, 0, 10 ether, uint64(block.timestamp + 1 days));
        vm.expectRevert(IntentExecutor.InvalidAmount.selector);
        executor.createIntent(params);
    }

    function testCreateIntentRevertsOnInvalidDirectionAndTriggerConfig() public {
        TriggerConfig memory trigger = _priceTrigger(1_000, true, 10_000);
        IntentParams memory params =
            _baseParams(TriggerType.PRICE, trigger, 10 ether, 10 ether, uint64(block.timestamp + 1 days));

        params.tokenOut = ALICE;
        vm.expectRevert(IntentExecutor.InvalidDirection.selector);
        executor.createIntent(params);

        params = _baseParams(TriggerType.PRICE, trigger, 10 ether, 10 ether, uint64(block.timestamp + 1 days));
        params.zeroForOne = false;
        vm.expectRevert(IntentExecutor.InvalidDirection.selector);
        executor.createIntent(params);

        params = _baseParams(TriggerType.PRICE, trigger, 10 ether, 10 ether, uint64(block.timestamp + 1 days));
        params.trigger.chunkBips = 10_001;
        vm.expectRevert(IntentExecutor.InvalidTrigger.selector);
        executor.createIntent(params);

        params = _baseParams(TriggerType.PRICE, _priceTrigger(0, true, 10_000), 10 ether, 10 ether, uint64(block.timestamp + 1 days));
        vm.expectRevert(IntentExecutor.InvalidTrigger.selector);
        executor.createIntent(params);

        TriggerConfig memory timeTrigger = TriggerConfig({
            targetSqrtPriceX96: 0,
            priceAbove: false,
            startTime: 0,
            endTime: 0,
            interval: 1,
            volatilityBps: 0,
            volatilityAbove: false,
            chunkBips: 1_000
        });
        params = _baseParams(TriggerType.TIME, timeTrigger, 10 ether, 1, uint64(block.timestamp + 1 days));
        vm.expectRevert(IntentExecutor.InvalidTrigger.selector);
        executor.createIntent(params);

        timeTrigger.startTime = uint64(block.timestamp + 100);
        timeTrigger.endTime = uint64(block.timestamp + 50);
        params = _baseParams(TriggerType.TIME, timeTrigger, 10 ether, 1, uint64(block.timestamp + 1 days));
        vm.expectRevert(IntentExecutor.InvalidTrigger.selector);
        executor.createIntent(params);

        TriggerConfig memory volTrigger = TriggerConfig({
            targetSqrtPriceX96: 0,
            priceAbove: false,
            startTime: 0,
            endTime: 0,
            interval: 0,
            volatilityBps: 0,
            volatilityAbove: true,
            chunkBips: 10_000
        });
        params = _baseParams(TriggerType.VOLATILITY, volTrigger, 10 ether, 1, uint64(block.timestamp + 1 days));
        vm.expectRevert(IntentExecutor.InvalidTrigger.selector);
        executor.createIntent(params);
    }

    function testCancelIntentRefundsRemainingAmount() public {
        bytes32 intentId = _createPriceIntent(150 ether, uint64(block.timestamp + 1 days), true);

        uint256 userBalanceBefore = token0.balanceOf(address(this));
        executor.cancelIntent(intentId);

        Intent memory intent = executor.getIntent(intentId);
        assertEq(uint8(intent.status), uint8(IntentStatus.CANCELLED));
        assertEq(intent.remainingAmount, 0);
        assertEq(token0.balanceOf(address(this)), userBalanceBefore + 150 ether);
    }

    function testCancelIntentRevertsIfNotFoundOrNotOwnerAndNoOpsIfAlreadyInactive() public {
        vm.expectRevert(abi.encodeWithSelector(IntentExecutor.IntentNotFound.selector, bytes32(0)));
        executor.cancelIntent(bytes32(0));

        bytes32 aliceIntent = _createPriceIntentAs(ALICE, 10 ether, uint64(block.timestamp + 1 days), true);
        vm.expectRevert(abi.encodeWithSelector(IntentExecutor.IntentNotOwned.selector, aliceIntent, address(this)));
        executor.cancelIntent(aliceIntent);

        bytes32 intentId = _createPriceIntent(10 ether, uint64(block.timestamp + 1 days), true);
        executor.cancelIntent(intentId);
        executor.cancelIntent(intentId);

        Intent memory intent = executor.getIntent(intentId);
        assertEq(uint8(intent.status), uint8(IntentStatus.CANCELLED));
    }

    function testUpdateIntentValidationPaths() public {
        TriggerConfig memory nextTrigger = _priceTrigger(1_111, true, 0);
        vm.expectRevert(abi.encodeWithSelector(IntentExecutor.IntentNotFound.selector, bytes32(uint256(1))));
        executor.updateIntent(bytes32(uint256(1)), 1 ether, uint64(block.timestamp + 1 days), nextTrigger);

        bytes32 aliceIntent = _createPriceIntentAs(ALICE, 10 ether, uint64(block.timestamp + 1 days), true);
        vm.expectRevert(abi.encodeWithSelector(IntentExecutor.IntentNotOwned.selector, aliceIntent, address(this)));
        executor.updateIntent(aliceIntent, 1 ether, uint64(block.timestamp + 1 days), nextTrigger);

        bytes32 intentId = _createPriceIntent(10 ether, uint64(block.timestamp + 1 days), true);
        vm.expectRevert(IntentExecutor.InvalidAmount.selector);
        executor.updateIntent(intentId, 0, uint64(block.timestamp + 1 days), nextTrigger);
        vm.expectRevert(IntentExecutor.InvalidAmount.selector);
        executor.updateIntent(intentId, 101 ether, uint64(block.timestamp + 1 days), nextTrigger);
        vm.expectRevert(IntentExecutor.InvalidExpiry.selector);
        executor.updateIntent(intentId, 1 ether, uint64(block.timestamp), nextTrigger);

        TriggerConfig memory invalidPriceTrigger = _priceTrigger(0, true, 0);
        vm.expectRevert(IntentExecutor.InvalidTrigger.selector);
        executor.updateIntent(intentId, 1 ether, uint64(block.timestamp + 1 days), invalidPriceTrigger);

        TriggerConfig memory invalidChunkTrigger = _priceTrigger(1_234, true, 10_001);
        vm.expectRevert(IntentExecutor.InvalidTrigger.selector);
        executor.updateIntent(intentId, 1 ether, uint64(block.timestamp + 1 days), invalidChunkTrigger);

        executor.cancelIntent(intentId);
        vm.expectRevert(IntentExecutor.InvalidTrigger.selector);
        executor.updateIntent(intentId, 1 ether, uint64(block.timestamp + 1 days), nextTrigger);
    }

    function testUpdateIntentDefaultsChunkBipsWhenZero() public {
        bytes32 intentId = _createPriceIntent(10 ether, uint64(block.timestamp + 1 days), true);
        TriggerConfig memory trigger = _priceTrigger(2_000, true, 0);
        executor.updateIntent(intentId, 5 ether, uint64(block.timestamp + 2 days), trigger);

        Intent memory intent = executor.getIntent(intentId);
        assertEq(intent.amountOutMin, 5 ether);
        assertEq(intent.trigger.chunkBips, 10_000);
    }

    function testExecuteIntentRevertsForUnauthorizedCallbackSender() public {
        bytes32 intentId = _createPriceIntent(100 ether, uint64(block.timestamp + 1 days), true);

        ExecutionContext memory ctx = _defaultContext();
        vm.expectRevert(abi.encodeWithSelector(IntentExecutor.UnauthorizedCallbackSender.selector, address(this)));
        executor.executeIntent(REACT_VM, intentId, 0, abi.encode(ctx));
    }

    function testExecuteIntentRevertsForUnauthorizedReactVM() public {
        bytes32 intentId = _createPriceIntent(100 ether, uint64(block.timestamp + 1 days), true);

        ExecutionContext memory ctx = _defaultContext();
        vm.prank(CALLBACK_PROXY);
        vm.expectRevert(abi.encodeWithSelector(IntentExecutor.UnauthorizedReactVM.selector, address(0x1234)));
        executor.executeIntent(address(0x1234), intentId, 0, abi.encode(ctx));
    }

    function testExecuteIntentPriceTriggerSuccess() public {
        bytes32 intentId = _createPriceIntent(100 ether, uint64(block.timestamp + 1 days), true);

        uint256 token1Before = token1.balanceOf(address(this));
        ExecutionContext memory ctx = _defaultContext();

        vm.prank(CALLBACK_PROXY);
        bool ok = executor.executeIntent(REACT_VM, intentId, 0, abi.encode(ctx));

        assertTrue(ok);

        Intent memory intent = executor.getIntent(intentId);
        assertEq(uint8(intent.status), uint8(IntentStatus.EXECUTED));
        assertEq(intent.nonce, 1);
        assertEq(intent.remainingAmount, 0);
        assertEq(token1.balanceOf(address(this)), token1Before + 100 ether);
    }

    function testExecuteIntentReturnsFalseWhenIntentInactive() public {
        bytes32 intentId = _createPriceIntent(10 ether, uint64(block.timestamp + 1 days), true);
        executor.cancelIntent(intentId);

        vm.prank(CALLBACK_PROXY);
        bool ok = executor.executeIntent(REACT_VM, intentId, 0, abi.encode(_defaultContext()));
        assertFalse(ok);
    }

    function testExecuteIntentNonceMismatchIsNoOp() public {
        bytes32 intentId = _createPriceIntent(100 ether, uint64(block.timestamp + 1 days), true);
        ExecutionContext memory ctx = _defaultContext();

        vm.prank(CALLBACK_PROXY);
        bool ok = executor.executeIntent(REACT_VM, intentId, 1, abi.encode(ctx));

        assertFalse(ok);

        Intent memory intent = executor.getIntent(intentId);
        assertEq(uint8(intent.status), uint8(IntentStatus.PENDING));
        assertEq(intent.nonce, 0);
        assertEq(intent.remainingAmount, 100 ether);
    }

    function testExecuteIntentMarksExpiredAndRefunds() public {
        bytes32 intentId = _createPriceIntent(100 ether, uint64(block.timestamp + 1), true);

        vm.warp(block.timestamp + 2);

        uint256 userBalanceBefore = token0.balanceOf(address(this));

        vm.prank(CALLBACK_PROXY);
        bool ok = executor.executeIntent(REACT_VM, intentId, 0, abi.encode(_defaultContext()));

        assertFalse(ok);

        Intent memory intent = executor.getIntent(intentId);
        assertEq(uint8(intent.status), uint8(IntentStatus.EXPIRED));
        assertEq(intent.remainingAmount, 0);
        assertEq(token0.balanceOf(address(this)), userBalanceBefore + 100 ether);
    }

    function testExecuteIntentContextAndTriggerChecks() public {
        bytes32 priceIntent = _createPriceIntent(100 ether, uint64(block.timestamp + 1 days), true);
        ExecutionContext memory invalidPriceCtx = _defaultContext();
        invalidPriceCtx.observedSqrtPriceX96 = 0;
        vm.prank(CALLBACK_PROXY);
        assertFalse(executor.executeIntent(REACT_VM, priceIntent, 0, abi.encode(invalidPriceCtx)));

        ExecutionContext memory notMetPriceCtx = _defaultContext();
        notMetPriceCtx.observedSqrtPriceX96 = 999;
        vm.prank(CALLBACK_PROXY);
        assertFalse(executor.executeIntent(REACT_VM, priceIntent, 0, abi.encode(notMetPriceCtx)));

        TriggerConfig memory timeTrigger = TriggerConfig({
            targetSqrtPriceX96: 0,
            priceAbove: false,
            startTime: uint64(block.timestamp + 100),
            endTime: uint64(block.timestamp + 200),
            interval: 10,
            volatilityBps: 0,
            volatilityAbove: false,
            chunkBips: 2_500
        });
        IntentParams memory timeParams = _baseParams(
            TriggerType.TIME, timeTrigger, 100 ether, 10 ether, uint64(block.timestamp + 1 days)
        );
        bytes32 timeIntent = executor.createIntent(timeParams);

        vm.prank(CALLBACK_PROXY);
        assertFalse(executor.executeIntent(REACT_VM, timeIntent, 0, ""));

        vm.warp(block.timestamp + 250);
        vm.prank(CALLBACK_PROXY);
        assertFalse(executor.executeIntent(REACT_VM, timeIntent, 0, ""));

        TriggerConfig memory volTrigger = TriggerConfig({
            targetSqrtPriceX96: 0,
            priceAbove: false,
            startTime: 0,
            endTime: 0,
            interval: 0,
            volatilityBps: 120,
            volatilityAbove: true,
            chunkBips: 10_000
        });
        IntentParams memory volParams = _baseParams(
            TriggerType.VOLATILITY, volTrigger, 100 ether, 10 ether, uint64(block.timestamp + 1 days)
        );
        bytes32 volIntent = executor.createIntent(volParams);

        ExecutionContext memory invalidVolCtx = _defaultContext();
        invalidVolCtx.observedVolatilityBps = 0;
        vm.prank(CALLBACK_PROXY);
        assertFalse(executor.executeIntent(REACT_VM, volIntent, 0, abi.encode(invalidVolCtx)));

        ExecutionContext memory belowVolCtx = _defaultContext();
        belowVolCtx.observedVolatilityBps = 100;
        vm.prank(CALLBACK_PROXY);
        assertFalse(executor.executeIntent(REACT_VM, volIntent, 0, abi.encode(belowVolCtx)));
    }

    function testExecuteIntentAdapterRevertRecordsFailure() public {
        bytes32 intentId = _createPriceIntent(100 ether, uint64(block.timestamp + 1 days), true);
        adapter.setRevert(true);

        vm.prank(CALLBACK_PROXY);
        bool ok = executor.executeIntent(REACT_VM, intentId, 0, abi.encode(_defaultContext()));
        assertFalse(ok);

        Intent memory intent = executor.getIntent(intentId);
        assertEq(uint8(intent.status), uint8(IntentStatus.PENDING));
        assertEq(intent.remainingAmount, 100 ether);
        assertEq(token0.balanceOf(address(executor)), 100 ether);
    }

    function testExecuteIntentRevertsOnSlippageExceeded() public {
        bytes32 intentId = _createPriceIntent(100 ether, uint64(block.timestamp + 1 days), true);
        adapter.setAmountOut(1);

        vm.prank(CALLBACK_PROXY);
        vm.expectRevert(abi.encodeWithSelector(IntentExecutor.SlippageExceeded.selector, 100 ether, 1));
        executor.executeIntent(REACT_VM, intentId, 0, abi.encode(_defaultContext()));
    }

    function testExecuteIntentTimeTriggerPartialFillsAndInterval() public {
        uint64 start = uint64(block.timestamp + 10);
        uint64 expiry = uint64(block.timestamp + 1 days);

        TriggerConfig memory trigger = TriggerConfig({
            targetSqrtPriceX96: 0,
            priceAbove: false,
            startTime: start,
            endTime: uint64(block.timestamp + 1 hours),
            interval: 30,
            volatilityBps: 0,
            volatilityAbove: false,
            chunkBips: 2_500
        });

        IntentParams memory params = IntentParams({
            poolKey: poolKey,
            tokenIn: address(token0),
            tokenOut: address(token1),
            zeroForOne: true,
            amountIn: 100 ether,
            amountOutMin: 100 ether,
            triggerType: TriggerType.TIME,
            trigger: trigger,
            expiry: expiry
        });

        bytes32 intentId = executor.createIntent(params);

        vm.warp(start);
        vm.prank(CALLBACK_PROXY);
        bool first = executor.executeIntent(REACT_VM, intentId, 0, abi.encode(_defaultContext()));
        assertTrue(first);

        Intent memory afterFirst = executor.getIntent(intentId);
        assertEq(afterFirst.remainingAmount, 75 ether);
        assertEq(afterFirst.nonce, 1);
        assertEq(uint8(afterFirst.status), uint8(IntentStatus.PENDING));

        vm.prank(CALLBACK_PROXY);
        bool secondEarly = executor.executeIntent(REACT_VM, intentId, 1, abi.encode(_defaultContext()));
        assertFalse(secondEarly);

        vm.warp(start + 31);
        vm.prank(CALLBACK_PROXY);
        bool second = executor.executeIntent(REACT_VM, intentId, 1, abi.encode(_defaultContext()));
        assertTrue(second);

        Intent memory afterSecond = executor.getIntent(intentId);
        assertEq(afterSecond.remainingAmount, 50 ether);
        assertEq(afterSecond.nonce, 2);
    }

    function testExecuteIntentTimeTriggerChunkRoundsUpToOne() public {
        TriggerConfig memory trigger = TriggerConfig({
            targetSqrtPriceX96: 0,
            priceAbove: false,
            startTime: uint64(block.timestamp),
            endTime: 0,
            interval: 0,
            volatilityBps: 0,
            volatilityAbove: false,
            chunkBips: 1
        });

        IntentParams memory params =
            _baseParams(TriggerType.TIME, trigger, 1, 1, uint64(block.timestamp + 1 days));
        bytes32 intentId = executor.createIntent(params);
        adapter.setAmountOut(1);

        vm.prank(CALLBACK_PROXY);
        bool ok = executor.executeIntent(REACT_VM, intentId, 0, "");
        assertTrue(ok);

        Intent memory intent = executor.getIntent(intentId);
        assertEq(uint8(intent.status), uint8(IntentStatus.EXECUTED));
        assertEq(intent.remainingAmount, 0);
    }

    function testExecuteIntentTimeTriggerCapsAtRemainingAndMinOutFloor() public {
        TriggerConfig memory trigger = TriggerConfig({
            targetSqrtPriceX96: 0,
            priceAbove: false,
            startTime: uint64(block.timestamp),
            endTime: 0,
            interval: 0,
            volatilityBps: 0,
            volatilityAbove: false,
            chunkBips: 9_000
        });

        IntentParams memory params =
            _baseParams(TriggerType.TIME, trigger, 100 ether, 1, uint64(block.timestamp + 1 days));
        bytes32 intentId = executor.createIntent(params);
        adapter.setAmountOut(2 ether);

        vm.prank(CALLBACK_PROXY);
        bool first = executor.executeIntent(REACT_VM, intentId, 0, "");
        assertTrue(first);

        Intent memory afterFirst = executor.getIntent(intentId);
        assertEq(afterFirst.remainingAmount, 10 ether);
        assertEq(uint8(afterFirst.status), uint8(IntentStatus.PENDING));

        vm.prank(CALLBACK_PROXY);
        bool second = executor.executeIntent(REACT_VM, intentId, 1, "");
        assertTrue(second);

        Intent memory afterSecond = executor.getIntent(intentId);
        assertEq(afterSecond.remainingAmount, 0);
        assertEq(uint8(afterSecond.status), uint8(IntentStatus.EXECUTED));
    }

    function testExecuteIntentRespectsMaxAmountInLimit() public {
        bytes32 intentId = _createPriceIntent(100 ether, uint64(block.timestamp + 1 days), true);

        ExecutionContext memory ctx = _defaultContext();
        ctx.maxAmountIn = 40 ether;
        adapter.setAmountOut(40 ether);

        vm.prank(CALLBACK_PROXY);
        bool ok = executor.executeIntent(REACT_VM, intentId, 0, abi.encode(ctx));
        assertTrue(ok);

        Intent memory intent = executor.getIntent(intentId);
        assertEq(intent.remainingAmount, 60 ether);
        assertEq(uint8(intent.status), uint8(IntentStatus.PENDING));
    }

    function testExecuteIntentRejectsCorruptedStateWithZeroExecutionAmount() public {
        bytes32 intentId = _createPriceIntent(100 ether, uint64(block.timestamp + 1 days), true);
        bytes32 baseSlot = keccak256(abi.encode(intentId, uint256(6)));

        for (uint256 i = 0; i < 24; i++) {
            bytes32 slot = bytes32(uint256(baseSlot) + i);
            if (uint256(vm.load(address(executor), slot)) == 100 ether) {
                vm.store(address(executor), slot, bytes32(0));
            }
        }

        vm.prank(CALLBACK_PROXY);
        bool ok = executor.executeIntent(REACT_VM, intentId, 0, abi.encode(_defaultContext()));
        assertFalse(ok);
    }

    function testExecuteIntentIsIdempotentAgainstReplayCallbacks() public {
        bytes32 intentId = _createPriceIntent(100 ether, uint64(block.timestamp + 1 days), true);

        vm.prank(CALLBACK_PROXY);
        bool first = executor.executeIntent(REACT_VM, intentId, 0, abi.encode(_defaultContext()));
        assertTrue(first);

        vm.prank(CALLBACK_PROXY);
        bool replay = executor.executeIntent(REACT_VM, intentId, 0, abi.encode(_defaultContext()));
        assertFalse(replay);

        Intent memory intent = executor.getIntent(intentId);
        assertEq(intent.nonce, 1);
        assertEq(uint8(intent.status), uint8(IntentStatus.EXECUTED));
    }

    function testExecuteIntentGuardsAgainstReentrancy() public {
        executor.setCallbackProxy(address(adapter));

        bytes32 intentId = _createPriceIntent(100 ether, uint64(block.timestamp + 1 days), true);
        ExecutionContext memory ctx = _defaultContext();

        adapter.setReenter(
            address(executor), abi.encodeCall(IntentExecutor.executeIntent, (REACT_VM, intentId, 0, abi.encode(ctx)))
        );

        vm.prank(address(adapter));
        bool ok = executor.executeIntent(REACT_VM, intentId, 0, abi.encode(ctx));

        assertTrue(ok);
        assertFalse(adapter.lastReenterSuccess());

        Intent memory intent = executor.getIntent(intentId);
        assertEq(uint8(intent.status), uint8(IntentStatus.EXECUTED));
    }

    function testFuzzRejectCreateIntentWithPastExpiry(uint64 offset) public {
        vm.assume(offset < 7 days);
        uint64 expiry = uint64(block.timestamp) > offset ? uint64(block.timestamp) - offset : uint64(block.timestamp);

        TriggerConfig memory trigger = TriggerConfig({
            targetSqrtPriceX96: 1,
            priceAbove: true,
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
            amountIn: 1 ether,
            amountOutMin: 1 ether,
            triggerType: TriggerType.PRICE,
            trigger: trigger,
            expiry: expiry
        });

        vm.expectRevert(IntentExecutor.InvalidExpiry.selector);
        executor.createIntent(params);
    }

    function testFuzzCreateAndCancelIntentRoundTrip(uint96 rawAmount, uint32 expiryOffset, bool priceAbove) public {
        vm.assume(rawAmount > 0);
        vm.assume(rawAmount <= 1_000_000 ether);
        vm.assume(expiryOffset > 0 && expiryOffset <= 30 days);
        uint256 amount = uint256(rawAmount);

        uint256 before = token0.balanceOf(address(this));
        bytes32 intentId = _createPriceIntent(amount, uint64(block.timestamp + expiryOffset), priceAbove);

        Intent memory created = executor.getIntent(intentId);
        assertEq(created.remainingAmount, amount);
        assertEq(uint8(created.status), uint8(IntentStatus.PENDING));

        executor.cancelIntent(intentId);

        Intent memory cancelled = executor.getIntent(intentId);
        assertEq(uint8(cancelled.status), uint8(IntentStatus.CANCELLED));
        assertEq(cancelled.remainingAmount, 0);
        assertEq(token0.balanceOf(address(this)), before);
    }

    function testFuzzExecuteIntentPriceTriggerDecision(
        uint96 rawAmount,
        uint160 target,
        uint160 observed,
        bool priceAbove,
        uint32 expiryOffset
    ) public {
        vm.assume(rawAmount > 0);
        vm.assume(rawAmount <= 1_000_000 ether);
        vm.assume(target > 0);
        vm.assume(expiryOffset > 0 && expiryOffset <= 30 days);

        uint256 amount = uint256(rawAmount);
        TriggerConfig memory trigger = _priceTrigger(target, priceAbove, 10_000);
        IntentParams memory params =
            _baseParams(TriggerType.PRICE, trigger, amount, amount, uint64(block.timestamp + expiryOffset));
        bytes32 intentId = executor.createIntent(params);

        adapter.setAmountOut(amount);
        ExecutionContext memory context = _defaultContext();
        context.observedSqrtPriceX96 = observed;

        bool shouldSucceed = observed > 0 && (priceAbove ? observed >= target : observed <= target);

        vm.prank(CALLBACK_PROXY);
        bool ok = executor.executeIntent(REACT_VM, intentId, 0, abi.encode(context));
        assertEq(ok, shouldSucceed);

        Intent memory intent = executor.getIntent(intentId);
        if (shouldSucceed) {
            assertEq(uint8(intent.status), uint8(IntentStatus.EXECUTED));
            assertEq(intent.nonce, 1);
        } else {
            assertEq(uint8(intent.status), uint8(IntentStatus.PENDING));
            assertEq(intent.nonce, 0);
        }
    }

    function testFuzzExecuteIntentVolatilityTriggerDecision(
        uint96 rawAmount,
        uint32 threshold,
        uint32 observed,
        bool above,
        uint32 expiryOffset
    ) public {
        vm.assume(rawAmount > 0);
        vm.assume(rawAmount <= 1_000_000 ether);
        vm.assume(threshold > 0);
        vm.assume(expiryOffset > 0 && expiryOffset <= 30 days);

        uint256 amount = uint256(rawAmount);
        TriggerConfig memory trigger = TriggerConfig({
            targetSqrtPriceX96: 0,
            priceAbove: false,
            startTime: 0,
            endTime: 0,
            interval: 0,
            volatilityBps: threshold,
            volatilityAbove: above,
            chunkBips: 10_000
        });

        IntentParams memory params =
            _baseParams(TriggerType.VOLATILITY, trigger, amount, amount, uint64(block.timestamp + expiryOffset));
        bytes32 intentId = executor.createIntent(params);

        adapter.setAmountOut(amount);
        ExecutionContext memory context = _defaultContext();
        context.observedVolatilityBps = observed;

        bool shouldSucceed = observed > 0 && (above ? observed >= threshold : observed <= threshold);

        vm.prank(CALLBACK_PROXY);
        bool ok = executor.executeIntent(REACT_VM, intentId, 0, abi.encode(context));
        assertEq(ok, shouldSucceed);
    }

    function testFuzzTimeTriggerExecutionAmountMath(uint96 rawAmount, uint16 chunkBips, uint96 rawMaxAmountIn) public {
        vm.assume(rawAmount > 0);
        vm.assume(rawAmount <= 1_000_000 ether);
        vm.assume(chunkBips > 0 && chunkBips <= 10_000);

        uint256 amount = uint256(rawAmount);
        uint256 maxAmountIn = uint256(rawMaxAmountIn);

        TriggerConfig memory trigger = TriggerConfig({
            targetSqrtPriceX96: 0,
            priceAbove: false,
            startTime: uint64(block.timestamp),
            endTime: uint64(block.timestamp + 1 days),
            interval: 0,
            volatilityBps: 0,
            volatilityAbove: false,
            chunkBips: chunkBips
        });

        IntentParams memory params = _baseParams(
            TriggerType.TIME, trigger, amount, amount, uint64(block.timestamp + 2 days)
        );
        bytes32 intentId = executor.createIntent(params);

        uint256 expected = (amount * chunkBips) / 10_000;
        if (expected == 0) {
            expected = 1;
        }
        if (expected > amount) {
            expected = amount;
        }
        if (maxAmountIn > 0 && maxAmountIn < expected) {
            expected = maxAmountIn;
        }
        vm.assume(expected > 0);

        adapter.setAmountOut(expected);

        ExecutionContext memory context = _defaultContext();
        context.maxAmountIn = maxAmountIn;

        vm.prank(CALLBACK_PROXY);
        bool ok = executor.executeIntent(REACT_VM, intentId, 0, abi.encode(context));
        assertTrue(ok);

        Intent memory updated = executor.getIntent(intentId);
        assertEq(updated.remainingAmount, amount - expected);
        if (amount == expected) {
            assertEq(uint8(updated.status), uint8(IntentStatus.EXECUTED));
        } else {
            assertEq(uint8(updated.status), uint8(IntentStatus.PENDING));
        }
    }

    function _baseParams(
        TriggerType triggerType,
        TriggerConfig memory trigger,
        uint256 amountIn,
        uint256 amountOutMin,
        uint64 expiry
    ) internal view returns (IntentParams memory params) {
        params = IntentParams({
            poolKey: poolKey,
            tokenIn: address(token0),
            tokenOut: address(token1),
            zeroForOne: true,
            amountIn: amountIn,
            amountOutMin: amountOutMin,
            triggerType: triggerType,
            trigger: trigger,
            expiry: expiry
        });
    }

    function _priceTrigger(uint160 targetSqrtPriceX96, bool priceAbove, uint16 chunkBips)
        internal
        pure
        returns (TriggerConfig memory)
    {
        return TriggerConfig({
            targetSqrtPriceX96: targetSqrtPriceX96,
            priceAbove: priceAbove,
            startTime: 0,
            endTime: 0,
            interval: 0,
            volatilityBps: 0,
            volatilityAbove: false,
            chunkBips: chunkBips
        });
    }

    function _createPriceIntent(uint256 amountIn, uint64 expiry, bool priceAbove) internal returns (bytes32) {
        IntentParams memory params = _baseParams(
            TriggerType.PRICE, _priceTrigger(1_000, priceAbove, 10_000), amountIn, amountIn, expiry
        );
        return executor.createIntent(params);
    }

    function _createPriceIntentAs(address user, uint256 amountIn, uint64 expiry, bool priceAbove)
        internal
        returns (bytes32)
    {
        IntentParams memory params = _baseParams(
            TriggerType.PRICE, _priceTrigger(1_000, priceAbove, 10_000), amountIn, amountIn, expiry
        );
        vm.prank(user);
        return executor.createIntent(params);
    }

    function _defaultContext() internal pure returns (ExecutionContext memory) {
        return ExecutionContext({
            observedSqrtPriceX96: 2_000,
            observedTick: 0,
            observedVolatilityBps: 100,
            maxAmountIn: 0,
            hookData: bytes("")
        });
    }
}
