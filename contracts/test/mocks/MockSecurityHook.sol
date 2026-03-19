// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ISecurityHook} from "src/interfaces/ISecurityHook.sol";
import {MitigationPayload} from "src/libraries/SecurityTypes.sol";

contract MockSecurityHook is ISecurityHook {
    bool public applyResult = true;
    bytes32 public lastPoolId;
    uint256 public lastNonce;
    MitigationPayload public lastPayload;

    function setApplyResult(bool result) external {
        applyResult = result;
    }

    function applyProtection(bytes32 poolId, uint256 nonce, MitigationPayload calldata payload)
        external
        override
        returns (bool)
    {
        lastPoolId = poolId;
        lastNonce = nonce;
        lastPayload = payload;
        return applyResult;
    }
}
