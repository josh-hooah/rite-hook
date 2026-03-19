// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {SecurityHook} from "../../src/SecurityHook.sol";
import {SecurityExecutor} from "../../src/SecurityExecutor.sol";
import {ISecurityHook} from "src/interfaces/ISecurityHook.sol";

import {MockPoolManager} from "../mocks/MockPoolManager.sol";

import {MitigationMode, MitigationPayload, ProtectionConfig, ProtectionState} from "src/libraries/SecurityTypes.sol";

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

contract SecurityLifecycleIntegrationTest is Test {
    using PoolIdLibrary for PoolKey;
    using LPFeeLibrary for uint24;

    MockPoolManager internal poolManager;
    SecurityHook internal securityHook;
    SecurityExecutor internal securityExecutor;

    MockERC20 internal token0;
    MockERC20 internal token1;

    PoolKey internal dynamicPoolKey;
    bytes32 internal poolId;

    address internal constant OWNER = address(0xA11CE);
    address internal constant CALLBACK_PROXY = address(0xBEEF);
    address internal constant REACT_VM = address(0xCAFE);

    function setUp() public {
        poolManager = new MockPoolManager();

        token0 = new MockERC20("Token0", "TK0", 18);
        token1 = new MockERC20("Token1", "TK1", 18);
        if (address(token0) > address(token1)) {
            (token0, token1) = (token1, token0);
        }

        address hookAddress = address(
            uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG) ^ (uint160(0x9999) << 144)
        );

        bytes memory constructorArgs = abi.encode(IPoolManager(address(poolManager)), OWNER, OWNER, uint32(8));
        deployCodeTo("SecurityHook.sol:SecurityHook", constructorArgs, hookAddress);
        securityHook = SecurityHook(hookAddress);

        vm.prank(OWNER);
        securityExecutor = new SecurityExecutor(OWNER, CALLBACK_PROXY, ISecurityHook(address(securityHook)));

        vm.prank(OWNER);
        securityHook.setSecurityExecutor(address(securityExecutor));

        vm.prank(OWNER);
        securityExecutor.setReactVM(REACT_VM, true);

        dynamicPoolKey = PoolKey({
            currency0: Currency.wrap(address(token0)),
            currency1: Currency.wrap(address(token1)),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 60,
            hooks: IHooks(address(securityHook))
        });

        poolId = PoolId.unwrap(dynamicPoolKey.toId());
        poolManager.setSlot0(poolId, uint160(2 ** 96), 10, 0, 3_000);

        vm.prank(OWNER);
        securityHook.setPoolProtectionConfig(
            poolId,
            ProtectionConfig({baseFeePips: 0, maxFeePips: 80_000, maxThrottleBps: 8_000, maxPauseSeconds: 600})
        );
    }

    function testCallbackMitigationAppliesAndEnforcesProtection() public {
        MitigationPayload memory mitigation = MitigationPayload({
            dynamicFeePips: 50_000,
            throttleBps: 3_000,
            maxTradeSize: 2 ether,
            pauseSeconds: 120,
            riskScoreBps: 8_900,
            mode: MitigationMode.COMBINED,
            reason: keccak256("CRITICAL_RISK")
        });

        vm.prank(CALLBACK_PROXY);
        bool accepted = securityExecutor.applyMitigation(REACT_VM, poolId, 1, abi.encode(mitigation));
        assertTrue(accepted);
        assertEq(securityExecutor.lastMitigationNonce(poolId), 1);

        ProtectionState memory state = securityHook.protectionStateByPoolId(poolId);
        assertEq(state.currentFeePips, mitigation.dynamicFeePips);
        assertEq(state.throttleBps, mitigation.throttleBps);
        assertEq(state.maxTradeSize, mitigation.maxTradeSize);
        assertEq(state.lastRiskScoreBps, mitigation.riskScoreBps);

        SwapParams memory params = SwapParams({zeroForOne: true, amountSpecified: -1 ether, sqrtPriceLimitX96: 0});

        vm.prank(address(poolManager));
        vm.expectRevert(
            abi.encodeWithSelector(SecurityHook.SecurityHook__PoolPaused.selector, poolId, state.pauseUntil)
        );
        securityHook.beforeSwap(address(this), dynamicPoolKey, params, bytes(""));

        vm.warp(block.timestamp + 121);

        vm.prank(address(poolManager));
        (,, uint24 feeOverride) = securityHook.beforeSwap(address(this), dynamicPoolKey, params, bytes(""));
        assertTrue(feeOverride.isOverride());
        assertEq(feeOverride.removeOverrideFlag(), mitigation.dynamicFeePips);
    }
}
