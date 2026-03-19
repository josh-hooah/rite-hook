// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {V4RouterDeployer} from "hookmate/artifacts/V4Router.sol";

contract DeployHookmateRouter is Script {
    function run() external {
        uint256 deployerPk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address poolManager = vm.envAddress("POOL_MANAGER");
        address permit2 = vm.envAddress("PERMIT2");

        vm.startBroadcast(deployerPk);
        address router = V4RouterDeployer.deploy(poolManager, permit2);
        vm.stopBroadcast();

        console2.log("HookmateV4Router:", router);
    }
}
