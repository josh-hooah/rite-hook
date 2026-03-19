// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";

import {SecurityExecutor} from "../../src/SecurityExecutor.sol";
import {MitigationMode, MitigationPayload} from "src/libraries/SecurityTypes.sol";
import {MockSecurityHook} from "../mocks/MockSecurityHook.sol";

contract SecurityExecutorUnitTest is Test {
    SecurityExecutor internal executor;
    MockSecurityHook internal mockHook;

    address internal constant OWNER = address(0xA11CE);
    address internal constant CALLBACK_PROXY = address(0xBEEF);
    address internal constant REACT_VM = address(0xC0FFEE);

    bytes32 internal constant POOL_ID = keccak256("pool-1");

    function setUp() public {
        mockHook = new MockSecurityHook();
        executor = new SecurityExecutor(OWNER, CALLBACK_PROXY, mockHook);

        vm.prank(OWNER);
        executor.setReactVM(REACT_VM, true);
    }

    function testConstructorRejectsZeroInputs() public {
        vm.expectRevert(SecurityExecutor.SecurityExecutor__ZeroAddress.selector);
        new SecurityExecutor(OWNER, address(0), mockHook);

        vm.expectRevert(SecurityExecutor.SecurityExecutor__ZeroAddress.selector);
        new SecurityExecutor(OWNER, CALLBACK_PROXY, MockSecurityHook(address(0)));
    }

    function testOwnerSettersValidateAccessAndBounds() public {
        vm.prank(OWNER);
        executor.setCallbackProxy(address(0x1234));
        assertEq(executor.callbackProxy(), address(0x1234));

        vm.prank(OWNER);
        executor.setSecurityHook(mockHook);
        assertEq(address(executor.securityHook()), address(mockHook));

        vm.prank(OWNER);
        executor.setReactVM(address(0x99), true);
        assertTrue(executor.reactVMAllowlist(address(0x99)));

        vm.prank(OWNER);
        vm.expectRevert(SecurityExecutor.SecurityExecutor__ZeroAddress.selector);
        executor.setCallbackProxy(address(0));

        vm.prank(OWNER);
        vm.expectRevert(SecurityExecutor.SecurityExecutor__ZeroAddress.selector);
        executor.setSecurityHook(MockSecurityHook(address(0)));

        vm.prank(OWNER);
        vm.expectRevert(SecurityExecutor.SecurityExecutor__ZeroAddress.selector);
        executor.setReactVM(address(0), true);

        vm.expectRevert();
        executor.setCallbackProxy(address(0x1));
    }

    function testApplyMitigationRevertsForUnauthorizedSender() public {
        vm.expectRevert(abi.encodeWithSelector(SecurityExecutor.SecurityExecutor__UnauthorizedCallbackSender.selector, address(this)));
        executor.applyMitigation(REACT_VM, POOL_ID, 1, _encodedPayload());
    }

    function testApplyMitigationRevertsForUnauthorizedReactVm() public {
        vm.prank(CALLBACK_PROXY);
        vm.expectRevert(
            abi.encodeWithSelector(SecurityExecutor.SecurityExecutor__UnauthorizedReactVM.selector, address(0xDEAD))
        );
        executor.applyMitigation(address(0xDEAD), POOL_ID, 1, _encodedPayload());
    }

    function testApplyMitigationRejectsStaleNonce() public {
        vm.prank(CALLBACK_PROXY);
        assertTrue(executor.applyMitigation(REACT_VM, POOL_ID, 1, _encodedPayload()));
        assertEq(executor.lastMitigationNonce(POOL_ID), 1);

        vm.prank(CALLBACK_PROXY);
        assertFalse(executor.applyMitigation(REACT_VM, POOL_ID, 1, _encodedPayload()));
        assertEq(executor.lastMitigationNonce(POOL_ID), 1);
    }

    function testApplyMitigationRejectsWhenHookReturnsFalse() public {
        mockHook.setApplyResult(false);

        vm.prank(CALLBACK_PROXY);
        assertFalse(executor.applyMitigation(REACT_VM, POOL_ID, 1, _encodedPayload()));
        assertEq(executor.lastMitigationNonce(POOL_ID), 0);
    }

    function testApplyMitigationSuccessUpdatesNonceAndForwardsPayload() public {
        vm.prank(CALLBACK_PROXY);
        bool success = executor.applyMitigation(REACT_VM, POOL_ID, 3, _encodedPayload());

        assertTrue(success);
        assertEq(executor.lastMitigationNonce(POOL_ID), 3);
        assertEq(mockHook.lastPoolId(), POOL_ID);
        assertEq(mockHook.lastNonce(), 3);

        (,,,, uint16 riskScoreBps,, bytes32 reason) = mockHook.lastPayload();
        assertEq(riskScoreBps, 8_800);
        assertEq(reason, keccak256("risk"));
    }

    function _encodedPayload() internal pure returns (bytes memory) {
        MitigationPayload memory payload = MitigationPayload({
            dynamicFeePips: 30_000,
            throttleBps: 1_500,
            maxTradeSize: 10 ether,
            pauseSeconds: 300,
            riskScoreBps: 8_800,
            mode: MitigationMode.COMBINED,
            reason: keccak256("risk")
        });

        return abi.encode(payload);
    }
}
