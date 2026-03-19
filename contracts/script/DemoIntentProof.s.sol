// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {IntentExecutor} from "../src/IntentExecutor.sol";
import {TriggerType, TriggerConfig, IntentParams, ExecutionContext} from "../src/libraries/IntentTypes.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";

/// @notice Onchain user-flow proof on public testnet:
/// - deploy demo tokens
/// - create intent
/// - callback execution attempt (expected adapter-revert path in demo setup)
/// - safe cancellation/refund
contract DemoIntentProof is Script {
    function run() external {
        uint256 deployerPk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(deployerPk);

        IntentExecutor executor = IntentExecutor(vm.envAddress("DESTINATION_EXECUTOR"));
        address hook = vm.envAddress("ORIGIN_HOOK");
        address reactVM = vm.envAddress("REACTIVE_INTENT_CONTRACT");

        vm.startBroadcast(deployerPk);

        MockERC20 tokenA = new MockERC20("RITE Demo Token A", "RDTA", 18);
        MockERC20 tokenB = new MockERC20("RITE Demo Token B", "RDTB", 18);

        tokenA.mint(deployer, 100 ether);
        tokenB.mint(deployer, 100 ether);

        (address currency0, address currency1) =
            address(tokenA) < address(tokenB) ? (address(tokenA), address(tokenB)) : (address(tokenB), address(tokenA));
        bool zeroForOne = address(tokenA) == currency0;
        address tokenIn = zeroForOne ? currency0 : currency1;
        address tokenOut = zeroForOne ? currency1 : currency0;

        PoolKey memory poolKey = PoolKey({
            currency0: Currency.wrap(currency0),
            currency1: Currency.wrap(currency1),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(hook)
        });

        TriggerConfig memory trigger = TriggerConfig({
            targetSqrtPriceX96: 0,
            priceAbove: false,
            startTime: uint64(block.timestamp - 1),
            endTime: 0,
            interval: 0,
            volatilityBps: 0,
            volatilityAbove: false,
            chunkBips: 10_000
        });

        IntentParams memory params = IntentParams({
            poolKey: poolKey,
            tokenIn: tokenIn,
            tokenOut: tokenOut,
            zeroForOne: zeroForOne,
            amountIn: 1 ether,
            amountOutMin: 1,
            triggerType: TriggerType.TIME,
            trigger: trigger,
            expiry: uint64(block.timestamp + 1 hours)
        });

        MockERC20(tokenIn).approve(address(executor), type(uint256).max);
        bytes32 intentId = executor.createIntent(params);

        ExecutionContext memory context = ExecutionContext({
            observedSqrtPriceX96: 1,
            observedTick: 0,
            observedVolatilityBps: 1,
            maxAmountIn: 0,
            hookData: bytes("")
        });

        // In this public-demo setup we intentionally expect adapter revert path.
        bool executed = executor.executeIntent(reactVM, intentId, 0, abi.encode(context));
        require(!executed, "DemoIntentProof: expected non-executed path");

        executor.cancelIntent(intentId);

        vm.stopBroadcast();

        console2.log("DemoTokenA:", address(tokenA));
        console2.log("DemoTokenB:", address(tokenB));
        console2.log("IntentId:", vm.toString(intentId));
        console2.log("Expected callback outcome: non-executed (adapter revert path), then cancelled");
    }
}
