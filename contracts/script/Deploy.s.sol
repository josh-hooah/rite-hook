// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";
import {IPermit2} from "permit2/src/interfaces/IPermit2.sol";
import {IUniswapV4Router04} from "hookmate/interfaces/router/IUniswapV4Router04.sol";

import {IntentHook} from "../src/IntentHook.sol";
import {IntentExecutor} from "../src/IntentExecutor.sol";
import {IIntentSwapAdapter} from "../src/interfaces/IIntentSwapAdapter.sol";
import {HookmateV4SwapAdapter} from "../src/adapters/HookmateV4SwapAdapter.sol";

import {SecurityHook} from "../src/SecurityHook.sol";
import {SecurityExecutor} from "../src/SecurityExecutor.sol";
import {ISecurityHook} from "src/interfaces/ISecurityHook.sol";

contract Deploy is Script {
    address internal constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    function run() external {
        uint256 deployerPk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address owner = vm.envAddress("OWNER");

        IPoolManager poolManager = IPoolManager(vm.envAddress("POOL_MANAGER"));
        address callbackProxy = vm.envAddress("CALLBACK_PROXY");
        uint32 volatilityWindow = uint32(vm.envOr("VOLATILITY_WINDOW", uint256(8)));

        address payable hookmateRouter = payable(vm.envOr("HOOKMATE_ROUTER", address(0)));
        address permit2 = vm.envOr("PERMIT2", address(0));
        bool deployIntentStack = vm.envOr("DEPLOY_INTENT_STACK", false);

        vm.startBroadcast(deployerPk);

        _deploySecurityStack(poolManager, owner, callbackProxy, volatilityWindow);

        if (deployIntentStack || (hookmateRouter != address(0) && permit2 != address(0))) {
            require(hookmateRouter != address(0), "Deploy: HOOKMATE_ROUTER required");
            require(permit2 != address(0), "Deploy: PERMIT2 required");
            _deployIntentStack(poolManager, owner, callbackProxy, volatilityWindow, hookmateRouter, permit2);
        } else {
            console2.log("Intent stack skipped (set DEPLOY_INTENT_STACK=true and provide HOOKMATE_ROUTER/PERMIT2)");
        }

        vm.stopBroadcast();
    }

    function _deploySecurityStack(IPoolManager poolManager, address owner, address callbackProxy, uint32 volatilityWindow)
        internal
    {
        uint160 flags = uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG);

        // Temporary executor placeholder is owner; set actual executor after deployment.
        bytes memory hookConstructorArgs = abi.encode(poolManager, owner, owner, volatilityWindow);
        (address minedHookAddress, bytes32 salt) =
            HookMiner.find(CREATE2_DEPLOYER, flags, type(SecurityHook).creationCode, hookConstructorArgs);

        SecurityHook hook = new SecurityHook{salt: salt}(poolManager, owner, owner, volatilityWindow);
        require(address(hook) == minedHookAddress, "Deploy: mined security hook mismatch");

        SecurityExecutor executor = new SecurityExecutor(owner, callbackProxy, ISecurityHook(address(hook)));
        hook.setSecurityExecutor(address(executor));

        console2.log("SecurityHook:", address(hook));
        console2.log("SecurityExecutor:", address(executor));
    }

    function _deployIntentStack(
        IPoolManager poolManager,
        address owner,
        address callbackProxy,
        uint32 volatilityWindow,
        address payable hookmateRouter,
        address permit2
    ) internal {
        uint160 flags = uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG);

        bytes memory intentHookConstructorArgs = abi.encode(poolManager, owner, volatilityWindow);
        (address minedIntentHookAddress, bytes32 intentHookSalt) =
            HookMiner.find(CREATE2_DEPLOYER, flags, type(IntentHook).creationCode, intentHookConstructorArgs);

        IntentHook intentHook = new IntentHook{salt: intentHookSalt}(poolManager, owner, volatilityWindow);
        require(address(intentHook) == minedIntentHookAddress, "Deploy: mined intent hook mismatch");

        HookmateV4SwapAdapter adapter = new HookmateV4SwapAdapter(
            owner,
            IUniswapV4Router04(hookmateRouter),
            IPermit2(permit2),
            address(poolManager)
        );

        IntentExecutor executor = new IntentExecutor(owner, callbackProxy, IIntentSwapAdapter(address(adapter)));
        adapter.setExecutor(address(executor));

        console2.log("IntentHook:", address(intentHook));
        console2.log("HookmateV4SwapAdapter:", address(adapter));
        console2.log("IntentExecutor:", address(executor));
    }
}
