// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {MitigationPayload} from "src/libraries/SecurityTypes.sol";

interface ISecurityHook {
    function applyProtection(bytes32 poolId, uint256 nonce, MitigationPayload calldata payload) external returns (bool);
}
