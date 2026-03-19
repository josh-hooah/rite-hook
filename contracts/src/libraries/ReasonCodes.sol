// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

library ReasonCodes {
    bytes32 internal constant OK = keccak256("OK");
    bytes32 internal constant TRIGGER_NOT_MET = keccak256("TRIGGER_NOT_MET");
    bytes32 internal constant NONCE_MISMATCH = keccak256("NONCE_MISMATCH");
    bytes32 internal constant INTENT_INACTIVE = keccak256("INTENT_INACTIVE");
    bytes32 internal constant EXPIRED = keccak256("EXPIRED");
    bytes32 internal constant ADAPTER_REVERT = keccak256("ADAPTER_REVERT");
    bytes32 internal constant INVALID_CONTEXT = keccak256("INVALID_CONTEXT");
}
