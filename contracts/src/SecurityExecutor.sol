// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {ISecurityHook} from "src/interfaces/ISecurityHook.sol";
import {MitigationPayload} from "src/libraries/SecurityTypes.sol";

/**
 * @title SecurityExecutor
 * @notice Destination-chain callback gate that authenticates ReactVM callbacks and applies mitigation atomically.
 * @custom:security-contact jesuorobonosakhare873@gmail.com
 */
contract SecurityExecutor is Ownable2Step, ReentrancyGuard {
    error SecurityExecutor__ZeroAddress();
    error SecurityExecutor__UnauthorizedCallbackSender(address caller);
    error SecurityExecutor__UnauthorizedReactVM(address reactVM);

    event CallbackProxyUpdated(address indexed callbackProxy);
    event ReactVMAllowlistUpdated(address indexed reactVM, bool allowed);
    event SecurityHookUpdated(address indexed securityHook);
    event MitigationAccepted(bytes32 indexed poolId, uint256 indexed nonce, uint16 riskScoreBps, bytes32 reason);
    event MitigationRejected(bytes32 indexed poolId, uint256 indexed nonce, bytes32 reason);

    bytes32 internal constant REJECT_STALE_NONCE = keccak256("STALE_NONCE");
    bytes32 internal constant REJECT_HOOK_NOOP = keccak256("HOOK_NOOP");

    address public callbackProxy;
    ISecurityHook public securityHook;

    mapping(address => bool) public reactVMAllowlist;
    mapping(bytes32 => uint256) public lastMitigationNonce;

    constructor(address initialOwner, address callbackProxy_, ISecurityHook securityHook_) Ownable(initialOwner) {
        if (callbackProxy_ == address(0) || address(securityHook_) == address(0)) {
            revert SecurityExecutor__ZeroAddress();
        }

        callbackProxy = callbackProxy_;
        securityHook = securityHook_;
    }

    /*//////////////////////////////////////////////////////////////
                            EXTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function setCallbackProxy(address callbackProxy_) external onlyOwner {
        if (callbackProxy_ == address(0)) {
            revert SecurityExecutor__ZeroAddress();
        }
        callbackProxy = callbackProxy_;
        emit CallbackProxyUpdated(callbackProxy_);
    }

    function setReactVM(address reactVM, bool allowed) external onlyOwner {
        if (reactVM == address(0)) {
            revert SecurityExecutor__ZeroAddress();
        }
        reactVMAllowlist[reactVM] = allowed;
        emit ReactVMAllowlistUpdated(reactVM, allowed);
    }

    function setSecurityHook(ISecurityHook securityHook_) external onlyOwner {
        if (address(securityHook_) == address(0)) {
            revert SecurityExecutor__ZeroAddress();
        }
        securityHook = securityHook_;
        emit SecurityHookUpdated(address(securityHook_));
    }

    /// @notice Callback entrypoint where the first argument is overwritten with ReactVM id by Reactive infra.
    function applyMitigation(address reactVM, bytes32 poolId, uint256 nonce, bytes calldata extra)
        external
        nonReentrant
        returns (bool)
    {
        if (msg.sender != callbackProxy) {
            revert SecurityExecutor__UnauthorizedCallbackSender(msg.sender);
        }
        if (!reactVMAllowlist[reactVM]) {
            revert SecurityExecutor__UnauthorizedReactVM(reactVM);
        }

        if (nonce <= lastMitigationNonce[poolId]) {
            emit MitigationRejected(poolId, nonce, REJECT_STALE_NONCE);
            return false;
        }

        MitigationPayload memory payload = abi.decode(extra, (MitigationPayload));
        bool applied = securityHook.applyProtection(poolId, nonce, payload);
        if (!applied) {
            emit MitigationRejected(poolId, nonce, REJECT_HOOK_NOOP);
            return false;
        }

        lastMitigationNonce[poolId] = nonce;
        emit MitigationAccepted(poolId, nonce, payload.riskScoreBps, payload.reason);
        return true;
    }
}
