// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ExecutionContext} from "./IntentTypes.sol";

library IntentEncoding {
    /// @notice First argument is intentionally placeholder address(0) because ReactVM overwrites it.
    function encodeExecuteIntentPayload(bytes32 intentId, uint256 nonce, ExecutionContext memory context)
        internal
        pure
        returns (bytes memory)
    {
        return abi.encodeWithSignature(
            "executeIntent(address,bytes32,uint256,bytes)", address(0), intentId, nonce, abi.encode(context)
        );
    }

    function decodeExecutionContext(bytes calldata extra) internal pure returns (ExecutionContext memory context) {
        if (extra.length == 0) {
            return ExecutionContext({
                observedSqrtPriceX96: 0,
                observedTick: 0,
                observedVolatilityBps: 0,
                maxAmountIn: 0,
                hookData: bytes("")
            });
        }
        context = abi.decode(extra, (ExecutionContext));
    }
}
