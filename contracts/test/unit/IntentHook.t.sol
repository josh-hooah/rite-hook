// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {IntentHook} from "../../src/IntentHook.sol";
import {MockPoolManager} from "../mocks/MockPoolManager.sol";

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {toBalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {ImmutableState} from "@uniswap/v4-periphery/src/base/ImmutableState.sol";

contract IntentHookUnitTest is Test {
    using PoolIdLibrary for PoolKey;

    MockPoolManager internal poolManager;
    IntentHook internal hook;

    MockERC20 internal token0;
    MockERC20 internal token1;

    PoolKey internal poolKey;
    bytes32 internal poolId;

    function setUp() public {
        poolManager = new MockPoolManager();

        token0 = new MockERC20("Token0", "TK0", 18);
        token1 = new MockERC20("Token1", "TK1", 18);

        if (address(token0) > address(token1)) {
            (token0, token1) = (token1, token0);
        }

        address hookAddress = address(
            uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG) ^ (uint160(0x4444) << 144)
        );
        bytes memory constructorArgs = abi.encode(IPoolManager(address(poolManager)), address(this), uint32(8));
        deployCodeTo("IntentHook.sol:IntentHook", constructorArgs, hookAddress);
        hook = IntentHook(hookAddress);

        poolKey = PoolKey({
            currency0: Currency.wrap(address(token0)),
            currency1: Currency.wrap(address(token1)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });

        poolId = PoolId.unwrap(poolKey.toId());
        poolManager.setSlot0(poolId, 1_000_000, 10, 0, 3_000);
    }

    function testOnlyPoolManagerEnforcedOnCoreHookFunctions() public {
        SwapParams memory params = SwapParams({zeroForOne: true, amountSpecified: -1 ether, sqrtPriceLimitX96: 0});

        vm.expectRevert(ImmutableState.NotPoolManager.selector);
        hook.beforeSwap(address(this), poolKey, params, hex"");

        vm.expectRevert(ImmutableState.NotPoolManager.selector);
        hook.afterSwap(address(this), poolKey, params, toBalanceDelta(-1, 1), hex"");
    }

    function testSwapHooksUpdateTelemetry() public {
        SwapParams memory params = SwapParams({zeroForOne: true, amountSpecified: -1 ether, sqrtPriceLimitX96: 0});

        vm.prank(address(poolManager));
        hook.beforeSwap(address(this), poolKey, params, hex"aa");

        poolManager.setSlot0(poolId, 1_250_000, 13, 0, 3_000);
        vm.prank(address(poolManager));
        hook.afterSwap(address(this), poolKey, params, toBalanceDelta(-1_000, 980), hex"");

        IntentHook.PoolTelemetry memory telemetry = hook.telemetryByPoolId(poolId);
        assertEq(telemetry.beforeSwapCount, 1);
        assertEq(telemetry.afterSwapCount, 1);
        assertEq(telemetry.tick, 13);
        assertEq(telemetry.sqrtPriceX96, 1_250_000);
        assertGt(telemetry.rollingVolatilityBps, 0);
        assertEq(telemetry.updatedAt, uint64(block.timestamp));
    }

    function testOwnerCanConfigureVolatilityWindow() public {
        hook.setVolatilityWindow(42);
        assertEq(hook.volatilityWindow(), 42);
    }

    function testTelemetryByPoolKeyMatchesPoolId() public {
        IntentHook.PoolTelemetry memory byPoolId = hook.telemetryByPoolId(poolId);
        IntentHook.PoolTelemetry memory byPoolKey = hook.telemetryByPoolKey(poolKey);

        assertEq(byPoolKey.beforeSwapCount, byPoolId.beforeSwapCount);
        assertEq(byPoolKey.afterSwapCount, byPoolId.afterSwapCount);
        assertEq(byPoolKey.tick, byPoolId.tick);
        assertEq(byPoolKey.sqrtPriceX96, byPoolId.sqrtPriceX96);
    }

    function testSetVolatilityWindowRevertsOnInvalidValues() public {
        vm.expectRevert(IntentHook.InvalidVolatilityWindow.selector);
        hook.setVolatilityWindow(0);

        vm.expectRevert(IntentHook.InvalidVolatilityWindow.selector);
        hook.setVolatilityWindow(7_201);
    }

    function testNonOwnerCannotConfigureVolatilityWindow() public {
        vm.prank(address(0xBEEF));
        vm.expectRevert();
        hook.setVolatilityWindow(42);
    }

    function testFuzzOwnerCanConfigureValidVolatilityWindow(uint32 window) public {
        vm.assume(window > 0 && window <= 7200);
        hook.setVolatilityWindow(window);
        assertEq(hook.volatilityWindow(), window);
    }

    function testFuzzSwapTelemetryTracksVolatilityAcrossTicks(int24 firstTick, int24 secondTick, uint160 sqrtPriceX96) public {
        vm.assume(firstTick >= -100_000 && firstTick <= 100_000);
        vm.assume(secondTick >= -100_000 && secondTick <= 100_000);
        vm.assume(sqrtPriceX96 > 0);

        SwapParams memory params = SwapParams({zeroForOne: true, amountSpecified: -1 ether, sqrtPriceLimitX96: 0});

        poolManager.setSlot0(poolId, 1_000_000, firstTick, 0, 3_000);
        vm.prank(address(poolManager));
        hook.beforeSwap(address(this), poolKey, params, hex"");

        IntentHook.PoolTelemetry memory before = hook.telemetryByPoolId(poolId);
        poolManager.setSlot0(poolId, sqrtPriceX96, secondTick, 0, 3_000);
        vm.prank(address(poolManager));
        hook.afterSwap(address(this), poolKey, params, toBalanceDelta(-10, 10), hex"");

        IntentHook.PoolTelemetry memory telemetry = hook.telemetryByPoolId(poolId);
        uint32 expectedAbs =
            before.tick >= secondTick ? uint32(uint24(before.tick - secondTick)) : uint32(uint24(secondTick - before.tick));

        assertEq(telemetry.tick, secondTick);
        assertEq(telemetry.sqrtPriceX96, sqrtPriceX96);
        assertEq(telemetry.rollingVolatilityBps, (uint256(before.rollingVolatilityBps) * (hook.volatilityWindow() - 1) + expectedAbs) / hook.volatilityWindow());
        assertEq(telemetry.beforeSwapCount, 1);
        assertEq(telemetry.afterSwapCount, 1);
    }
}
