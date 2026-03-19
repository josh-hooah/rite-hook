// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {SecurityHook} from "../../src/SecurityHook.sol";
import {MockPoolManager} from "../mocks/MockPoolManager.sol";

import {MitigationMode, MitigationPayload, ProtectionConfig, ProtectionState, PoolTelemetry} from "src/libraries/SecurityTypes.sol";

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {toBalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {ImmutableState} from "@uniswap/v4-periphery/src/base/ImmutableState.sol";

contract SecurityHookUnitTest is Test {
    using PoolIdLibrary for PoolKey;
    using LPFeeLibrary for uint24;

    MockPoolManager internal poolManager;
    SecurityHook internal hook;

    MockERC20 internal token0;
    MockERC20 internal token1;

    PoolKey internal dynamicPoolKey;
    PoolKey internal staticPoolKey;

    bytes32 internal dynamicPoolId;
    bytes32 internal staticPoolId;

    address internal constant SECURITY_EXECUTOR = address(0xCAFE);

    function setUp() public {
        poolManager = new MockPoolManager();

        token0 = new MockERC20("Token0", "TK0", 18);
        token1 = new MockERC20("Token1", "TK1", 18);
        if (address(token0) > address(token1)) {
            (token0, token1) = (token1, token0);
        }

        address hookAddress = address(
            uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG) ^ (uint160(0x7777) << 144)
        );
        bytes memory constructorArgs = abi.encode(IPoolManager(address(poolManager)), address(this), SECURITY_EXECUTOR, uint32(8));
        deployCodeTo("SecurityHook.sol:SecurityHook", constructorArgs, hookAddress);
        hook = SecurityHook(hookAddress);

        dynamicPoolKey = PoolKey({
            currency0: Currency.wrap(address(token0)),
            currency1: Currency.wrap(address(token1)),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });

        staticPoolKey = PoolKey({
            currency0: Currency.wrap(address(token0)),
            currency1: Currency.wrap(address(token1)),
            fee: 3_000,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });

        dynamicPoolId = PoolId.unwrap(dynamicPoolKey.toId());
        staticPoolId = PoolId.unwrap(staticPoolKey.toId());

        poolManager.setSlot0(dynamicPoolId, 1_000_000, 10, 0, 3_000);
        poolManager.setSlot0(staticPoolId, 1_000_000, 10, 0, 3_000);
    }

    function testOnlyPoolManagerCanInvokeSwapHooks() public {
        SwapParams memory params = SwapParams({zeroForOne: true, amountSpecified: -1 ether, sqrtPriceLimitX96: 0});

        vm.expectRevert(ImmutableState.NotPoolManager.selector);
        hook.beforeSwap(address(this), dynamicPoolKey, params, bytes(""));

        vm.expectRevert(ImmutableState.NotPoolManager.selector);
        hook.afterSwap(address(this), dynamicPoolKey, params, toBalanceDelta(-100, 95), bytes(""));
    }

    function testAfterSwapUpdatesSecurityTelemetry() public {
        SwapParams memory params = SwapParams({zeroForOne: true, amountSpecified: -2 ether, sqrtPriceLimitX96: 0});

        uint160 startPrice = uint160(2 ** 96);
        uint160 midPrice = uint160((uint256(startPrice) * 105) / 100);
        uint160 nextPrice = uint160((uint256(startPrice) * 110) / 100);
        poolManager.setSlot0(staticPoolId, startPrice, 10, 0, 3_000);

        vm.prank(address(poolManager));
        hook.beforeSwap(address(this), staticPoolKey, params, bytes(""));

        poolManager.setSlot0(staticPoolId, midPrice, 16, 0, 3_000);
        vm.prank(address(poolManager));
        hook.afterSwap(address(this), staticPoolKey, params, toBalanceDelta(-2_000, 1_980), bytes(""));

        vm.prank(address(poolManager));
        hook.beforeSwap(address(this), staticPoolKey, params, bytes(""));

        poolManager.setSlot0(staticPoolId, nextPrice, 22, 0, 3_000);
        vm.prank(address(poolManager));
        hook.afterSwap(address(this), staticPoolKey, params, toBalanceDelta(-2_000, 1_930), bytes(""));

        PoolTelemetry memory telemetry = hook.telemetryByPoolId(staticPoolId);
        assertEq(telemetry.beforeSwapCount, 2);
        assertEq(telemetry.afterSwapCount, 2);
        assertEq(telemetry.tick, 22);
        assertEq(telemetry.sqrtPriceX96, nextPrice);
        assertGt(telemetry.rollingVolatilityBps, 0);
        assertGt(telemetry.priceDeviationBps, 0);
        assertGt(telemetry.slippageBps, 0);
        assertGt(telemetry.liquidityImbalanceBps, 0);
        assertGt(telemetry.rollingVolume, 0);
    }

    function testOwnerCanConfigureProtectionAndExecutorOnlyAppliesMitigation() public {
        ProtectionConfig memory cfg =
            ProtectionConfig({baseFeePips: 0, maxFeePips: 20_000, maxThrottleBps: 8_000, maxPauseSeconds: 120});
        hook.setPoolProtectionConfig(dynamicPoolId, cfg);

        MitigationPayload memory payload = MitigationPayload({
            dynamicFeePips: 12_000,
            throttleBps: 3_000,
            maxTradeSize: 1 ether,
            pauseSeconds: 60,
            riskScoreBps: 7_000,
            mode: MitigationMode.COMBINED,
            reason: keccak256("risk")
        });

        vm.expectRevert(abi.encodeWithSelector(SecurityHook.SecurityHook__UnauthorizedExecutor.selector, address(this)));
        hook.applyProtection(dynamicPoolId, 1, payload);

        vm.prank(SECURITY_EXECUTOR);
        bool applied = hook.applyProtection(dynamicPoolId, 1, payload);
        assertTrue(applied);

        ProtectionState memory state = hook.protectionStateByPoolId(dynamicPoolId);
        assertEq(state.currentFeePips, payload.dynamicFeePips);
        assertEq(state.throttleBps, payload.throttleBps);
        assertEq(state.maxTradeSize, payload.maxTradeSize);
        assertEq(state.lastRiskScoreBps, payload.riskScoreBps);
        assertEq(state.nonce, 1);

        vm.prank(SECURITY_EXECUTOR);
        assertFalse(hook.applyProtection(dynamicPoolId, 1, payload));
    }

    function testBeforeSwapEnforcesPauseAndThrottleRules() public {
        ProtectionConfig memory cfg =
            ProtectionConfig({baseFeePips: 0, maxFeePips: 30_000, maxThrottleBps: 5_000, maxPauseSeconds: 120});
        hook.setPoolProtectionConfig(dynamicPoolId, cfg);

        MitigationPayload memory pausePayload = MitigationPayload({
            dynamicFeePips: 10_000,
            throttleBps: 0,
            maxTradeSize: 0,
            pauseSeconds: 30,
            riskScoreBps: 8_000,
            mode: MitigationMode.PAUSE,
            reason: keccak256("pause")
        });

        vm.prank(SECURITY_EXECUTOR);
        hook.applyProtection(dynamicPoolId, 1, pausePayload);

        ProtectionState memory paused = hook.protectionStateByPoolId(dynamicPoolId);
        SwapParams memory params = SwapParams({zeroForOne: true, amountSpecified: -2 ether, sqrtPriceLimitX96: 0});

        vm.prank(address(poolManager));
        vm.expectRevert(
            abi.encodeWithSelector(SecurityHook.SecurityHook__PoolPaused.selector, dynamicPoolId, paused.pauseUntil)
        );
        hook.beforeSwap(address(this), dynamicPoolKey, params, bytes(""));

        vm.warp(block.timestamp + 31);

        MitigationPayload memory throttlePayload = MitigationPayload({
            dynamicFeePips: 10_000,
            throttleBps: 0,
            maxTradeSize: 1,
            pauseSeconds: 0,
            riskScoreBps: 7_000,
            mode: MitigationMode.THROTTLE,
            reason: keccak256("throttle")
        });

        vm.prank(SECURITY_EXECUTOR);
        hook.applyProtection(dynamicPoolId, 2, throttlePayload);

        vm.prank(address(poolManager));
        vm.expectRevert(abi.encodeWithSelector(SecurityHook.SecurityHook__SwapThrottled.selector, dynamicPoolId, 2 ether, 1));
        hook.beforeSwap(address(this), dynamicPoolKey, params, bytes(""));
    }

    function testBeforeSwapReturnsDynamicFeeOverrideForDynamicPoolOnly() public {
        ProtectionConfig memory cfg =
            ProtectionConfig({baseFeePips: 500, maxFeePips: 20_000, maxThrottleBps: 8_000, maxPauseSeconds: 120});
        hook.setPoolProtectionConfig(dynamicPoolId, cfg);
        hook.setPoolProtectionConfig(staticPoolId, cfg);

        MitigationPayload memory payload = MitigationPayload({
            dynamicFeePips: 12_345,
            throttleBps: 0,
            maxTradeSize: 0,
            pauseSeconds: 0,
            riskScoreBps: 6_500,
            mode: MitigationMode.ADAPTIVE_FEE,
            reason: keccak256("fee")
        });

        vm.prank(SECURITY_EXECUTOR);
        hook.applyProtection(dynamicPoolId, 1, payload);

        SwapParams memory params = SwapParams({zeroForOne: true, amountSpecified: -1 ether, sqrtPriceLimitX96: 0});

        vm.prank(address(poolManager));
        (,, uint24 dynamicOverride) = hook.beforeSwap(address(this), dynamicPoolKey, params, bytes(""));
        assertTrue(dynamicOverride.isOverride());
        assertEq(dynamicOverride.removeOverrideFlag(), payload.dynamicFeePips);

        vm.prank(address(poolManager));
        (,, uint24 staticOverride) = hook.beforeSwap(address(this), staticPoolKey, params, bytes(""));
        assertEq(staticOverride, 0);
    }

    function testApplyProtectionClampsPauseAndViewAccessors() public {
        ProtectionConfig memory cfg =
            ProtectionConfig({baseFeePips: 500, maxFeePips: 20_000, maxThrottleBps: 8_000, maxPauseSeconds: 10});
        hook.setPoolProtectionConfig(dynamicPoolId, cfg);

        MitigationPayload memory payload = MitigationPayload({
            dynamicFeePips: 12_345,
            throttleBps: 0,
            maxTradeSize: 0,
            pauseSeconds: 120,
            riskScoreBps: 8_400,
            mode: MitigationMode.PAUSE,
            reason: keccak256("clamp")
        });

        vm.prank(SECURITY_EXECUTOR);
        hook.applyProtection(dynamicPoolId, 1, payload);

        ProtectionState memory state = hook.protectionStateByPoolId(dynamicPoolId);
        assertEq(state.pauseUntil, uint64(block.timestamp) + 10);

        ProtectionConfig memory stored = hook.protectionConfigByPoolId(dynamicPoolId);
        assertEq(stored.maxPauseSeconds, cfg.maxPauseSeconds);
        assertEq(stored.maxFeePips, cfg.maxFeePips);

        ProtectionConfig memory defaultCfg = hook.protectionConfigByPoolId(staticPoolId);
        assertEq(defaultCfg.maxPauseSeconds, 3_600);
        assertEq(defaultCfg.maxThrottleBps, 10_000);
        assertEq(defaultCfg.maxFeePips, 300_000);

        SwapParams memory params = SwapParams({zeroForOne: true, amountSpecified: -1 ether, sqrtPriceLimitX96: 0});
        vm.prank(address(poolManager));
        hook.afterSwap(address(this), dynamicPoolKey, params, toBalanceDelta(-1_000, 980), bytes(""));

        PoolTelemetry memory byId = hook.telemetryByPoolId(dynamicPoolId);
        PoolTelemetry memory byKey = hook.telemetryByPoolKey(dynamicPoolKey);
        assertEq(byId.sequence, byKey.sequence);
        assertEq(byId.afterSwapCount, byKey.afterSwapCount);
    }

    function testBeforeSwapThrottleUsesRollingVolumeAndRoundsMinimumAllowanceToOne() public {
        hook.setVolatilityWindow(1);

        SwapParams memory seedParams = SwapParams({zeroForOne: true, amountSpecified: -1, sqrtPriceLimitX96: 0});
        vm.prank(address(poolManager));
        hook.afterSwap(address(this), dynamicPoolKey, seedParams, toBalanceDelta(-1, 1), bytes(""));

        PoolTelemetry memory seeded = hook.telemetryByPoolId(dynamicPoolId);
        assertEq(seeded.rollingVolume, 1);

        ProtectionConfig memory cfg =
            ProtectionConfig({baseFeePips: 0, maxFeePips: 20_000, maxThrottleBps: 8_000, maxPauseSeconds: 120});
        hook.setPoolProtectionConfig(dynamicPoolId, cfg);

        MitigationPayload memory payload = MitigationPayload({
            dynamicFeePips: 0,
            throttleBps: 1,
            maxTradeSize: 0,
            pauseSeconds: 0,
            riskScoreBps: 7_500,
            mode: MitigationMode.THROTTLE,
            reason: keccak256("throttle")
        });

        vm.prank(SECURITY_EXECUTOR);
        hook.applyProtection(dynamicPoolId, 1, payload);

        SwapParams memory blocked = SwapParams({zeroForOne: true, amountSpecified: -2, sqrtPriceLimitX96: 0});
        vm.prank(address(poolManager));
        vm.expectRevert(abi.encodeWithSelector(SecurityHook.SecurityHook__SwapThrottled.selector, dynamicPoolId, 2, 1));
        hook.beforeSwap(address(this), dynamicPoolKey, blocked, bytes(""));
    }

    function testAfterSwapHandlesZeroAndTinyPriceSlippageBranches() public {
        SwapParams memory params = SwapParams({zeroForOne: true, amountSpecified: -100, sqrtPriceLimitX96: 0});

        poolManager.setSlot0(dynamicPoolId, 0, 10, 0, 3_000);
        vm.prank(address(poolManager));
        hook.afterSwap(address(this), dynamicPoolKey, params, toBalanceDelta(0, 100), bytes(""));
        assertEq(hook.telemetryByPoolId(dynamicPoolId).slippageBps, 0);

        poolManager.setSlot0(dynamicPoolId, 1, 11, 0, 3_000);
        vm.prank(address(poolManager));
        hook.afterSwap(address(this), dynamicPoolKey, params, toBalanceDelta(-100, 100), bytes(""));
        assertEq(hook.telemetryByPoolId(dynamicPoolId).slippageBps, 0);
    }

    function testRevertsForInvalidOwnerInputsAndConfigBounds() public {
        vm.expectRevert(SecurityHook.SecurityHook__InvalidVolatilityWindow.selector);
        hook.setVolatilityWindow(0);

        vm.expectRevert(SecurityHook.SecurityHook__InvalidVolatilityWindow.selector);
        hook.setVolatilityWindow(7_201);

        vm.expectRevert(SecurityHook.SecurityHook__ZeroAddress.selector);
        hook.setSecurityExecutor(address(0));

        vm.prank(address(0xBEEF));
        vm.expectRevert();
        hook.setSecurityExecutor(address(0x1));

        ProtectionConfig memory invalidCfg =
            ProtectionConfig({baseFeePips: 2_000, maxFeePips: 1_000, maxThrottleBps: 8_000, maxPauseSeconds: 100});
        vm.expectRevert(SecurityHook.SecurityHook__InvalidProtectionConfig.selector);
        hook.setPoolProtectionConfig(dynamicPoolId, invalidCfg);

        ProtectionConfig memory validCfg =
            ProtectionConfig({baseFeePips: 0, maxFeePips: 1_000, maxThrottleBps: 2_000, maxPauseSeconds: 100});
        hook.setPoolProtectionConfig(dynamicPoolId, validCfg);

        MitigationPayload memory excessiveFee = MitigationPayload({
            dynamicFeePips: 1_001,
            throttleBps: 1_000,
            maxTradeSize: 0,
            pauseSeconds: 0,
            riskScoreBps: 5_000,
            mode: MitigationMode.ADAPTIVE_FEE,
            reason: keccak256("fee")
        });

        vm.prank(SECURITY_EXECUTOR);
        vm.expectRevert(SecurityHook.SecurityHook__InvalidProtectionConfig.selector);
        hook.applyProtection(dynamicPoolId, 1, excessiveFee);

        MitigationPayload memory excessiveThrottle = MitigationPayload({
            dynamicFeePips: 900,
            throttleBps: 2_001,
            maxTradeSize: 0,
            pauseSeconds: 0,
            riskScoreBps: 5_000,
            mode: MitigationMode.THROTTLE,
            reason: keccak256("throttle")
        });

        vm.prank(SECURITY_EXECUTOR);
        vm.expectRevert(SecurityHook.SecurityHook__InvalidProtectionConfig.selector);
        hook.applyProtection(dynamicPoolId, 2, excessiveThrottle);
    }
}
