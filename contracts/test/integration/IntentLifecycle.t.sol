// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {IntentHook} from "../../src/IntentHook.sol";
import {IntentExecutor} from "../../src/IntentExecutor.sol";
import {TriggerType, TriggerConfig, IntentParams, IntentStatus, Intent, ExecutionContext} from "../../src/libraries/IntentTypes.sol";
import {IIntentSwapAdapter} from "../../src/interfaces/IIntentSwapAdapter.sol";

import {BaseTest} from "../utils/BaseTest.sol";
import {EasyPosm} from "../utils/libraries/EasyPosm.sol";

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {Constants} from "@uniswap/v4-core/test/utils/Constants.sol";

import {MockSwapAdapter} from "../mocks/MockSwapAdapter.sol";

contract IntentLifecycleIntegrationTest is BaseTest {
    using EasyPosm for IPositionManager;
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    Currency internal currency0;
    Currency internal currency1;

    PoolKey internal poolKey;
    PoolId internal poolId;

    IntentHook internal hook;
    IntentExecutor internal executor;
    MockSwapAdapter internal adapter;

    address internal constant CALLBACK_PROXY = address(0xCBAC);
    address internal constant REACT_VM = address(0xF00D);

    function setUp() public {
        deployArtifactsAndLabel();
        (currency0, currency1) = deployCurrencyPair();

        address hookAddress = address(
            uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG) ^ (uint160(0x7777) << 144)
        );
        bytes memory constructorArgs = abi.encode(poolManager, address(this), uint32(8));
        deployCodeTo("IntentHook.sol:IntentHook", constructorArgs, hookAddress);
        hook = IntentHook(hookAddress);

        poolKey = PoolKey(currency0, currency1, 3000, 60, IHooks(hookAddress));
        poolId = poolKey.toId();

        poolManager.initialize(poolKey, Constants.SQRT_PRICE_1_1);

        int24 tickLower = TickMath.minUsableTick(poolKey.tickSpacing);
        int24 tickUpper = TickMath.maxUsableTick(poolKey.tickSpacing);

        uint128 liquidityAmount = 100e18;
        (uint256 amount0Expected, uint256 amount1Expected) = LiquidityAmounts.getAmountsForLiquidity(
            Constants.SQRT_PRICE_1_1,
            TickMath.getSqrtPriceAtTick(tickLower),
            TickMath.getSqrtPriceAtTick(tickUpper),
            liquidityAmount
        );

        positionManager.mint(
            poolKey,
            tickLower,
            tickUpper,
            liquidityAmount,
            amount0Expected + 1,
            amount1Expected + 1,
            address(this),
            block.timestamp,
            Constants.ZERO_BYTES
        );

        adapter = new MockSwapAdapter();
        adapter.setAmountOut(1 ether);

        executor = new IntentExecutor(address(this), CALLBACK_PROXY, IIntentSwapAdapter(address(adapter)));
        executor.setReactVM(REACT_VM, true);

        MockERC20(Currency.unwrap(currency1)).mint(address(adapter), 10_000 ether);
        MockERC20(Currency.unwrap(currency0)).approve(address(executor), type(uint256).max);
    }

    function testFullLifecycle_CreateIntentToHookToCallbackExecution() public {
        bytes32 intentId = _createPriceIntent();

        // Origin chain transaction emits hook telemetry in a real v4 swap.
        swapRouter.swapExactTokensForTokens({
            amountIn: 1 ether,
            amountOutMin: 0,
            zeroForOne: true,
            poolKey: poolKey,
            hookData: Constants.ZERO_BYTES,
            receiver: address(this),
            deadline: block.timestamp + 1
        });

        uint256 userToken1AfterSwap = MockERC20(Currency.unwrap(currency1)).balanceOf(address(this));

        IntentHook.PoolTelemetry memory telemetry = hook.telemetryByPoolId(PoolId.unwrap(poolId));
        assertEq(hook.telemetryByPoolId(PoolId.unwrap(poolId)).beforeSwapCount, 1);
        assertEq(hook.telemetryByPoolId(PoolId.unwrap(poolId)).afterSwapCount, 1);

        // Reactive decision simulation: use observed telemetry to build callback payload context.
        ExecutionContext memory context = ExecutionContext({
            observedSqrtPriceX96: telemetry.sqrtPriceX96,
            observedTick: telemetry.tick,
            observedVolatilityBps: telemetry.rollingVolatilityBps,
            maxAmountIn: 0,
            hookData: bytes("")
        });

        vm.prank(CALLBACK_PROXY);
        bool ok = executor.executeIntent(REACT_VM, intentId, 0, abi.encode(context));
        assertTrue(ok);

        Intent memory intent = executor.getIntent(intentId);
        assertEq(uint8(intent.status), uint8(IntentStatus.EXECUTED));
        assertEq(intent.nonce, 1);

        uint256 userToken1After = MockERC20(Currency.unwrap(currency1)).balanceOf(address(this));
        assertEq(userToken1After, userToken1AfterSwap + 1 ether);
    }

    function _createPriceIntent() internal returns (bytes32) {
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
            tokenIn: Currency.unwrap(currency0),
            tokenOut: Currency.unwrap(currency1),
            zeroForOne: true,
            amountIn: 1 ether,
            amountOutMin: 1,
            triggerType: TriggerType.PRICE,
            trigger: trigger,
            expiry: uint64(block.timestamp + 1 days)
        });

        return executor.createIntent(params);
    }
}
