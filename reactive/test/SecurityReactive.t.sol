// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";

import {IReactive} from "../src/lib/ReactiveBase.sol";
import {SecurityReactive} from "../src/SecurityReactive.sol";

contract SecurityReactiveUnitTest is Test {
    SecurityReactive internal reactive;

    address internal constant OWNER = address(0xA11CE);
    address internal constant HOOK = address(0xBEEF);
    address internal constant EXECUTOR = address(0xCAFE);

    uint256 internal constant ORIGIN_CHAIN_ID = 84532;
    uint256 internal constant DESTINATION_CHAIN_ID = 84532;

    uint256 internal constant SECURITY_TELEMETRY_TOPIC_0 =
        uint256(
            keccak256(
                "SecurityTelemetry(bytes32,address,bool,int256,int24,uint160,uint32,uint32,uint32,uint32,uint128,uint64,uint64)"
            )
        );

    bytes32 internal constant CALLBACK_TOPIC_0 = keccak256("Callback(uint256,address,uint64,bytes)");
    bytes32 internal constant CALLBACK_QUEUED_TOPIC_0 =
        keccak256("CallbackQueued(bytes32,uint256,uint8,uint16,bytes32)");

    function setUp() public {
        reactive = new SecurityReactive(OWNER, ORIGIN_CHAIN_ID, DESTINATION_CHAIN_ID, HOOK, EXECUTOR, 1_500_000);
    }

    function testConstructorRejectsInvalidConfig() public {
        vm.expectRevert(SecurityReactive.SecurityReactive__InvalidConfig.selector);
        new SecurityReactive(address(0), ORIGIN_CHAIN_ID, DESTINATION_CHAIN_ID, HOOK, EXECUTOR, 1);

        vm.expectRevert(SecurityReactive.SecurityReactive__InvalidConfig.selector);
        new SecurityReactive(OWNER, ORIGIN_CHAIN_ID, DESTINATION_CHAIN_ID, address(0), EXECUTOR, 1);

        vm.expectRevert(SecurityReactive.SecurityReactive__InvalidConfig.selector);
        new SecurityReactive(OWNER, ORIGIN_CHAIN_ID, DESTINATION_CHAIN_ID, HOOK, address(0), 1);

        vm.expectRevert(SecurityReactive.SecurityReactive__InvalidConfig.selector);
        new SecurityReactive(OWNER, ORIGIN_CHAIN_ID, DESTINATION_CHAIN_ID, HOOK, EXECUTOR, 0);
    }

    function testOwnerSettersEnforceAccessAndValidation() public {
        vm.prank(OWNER);
        reactive.setCallbackGasLimit(2_000_000);
        assertEq(reactive.callbackGasLimit(), 2_000_000);

        SecurityReactive.RiskConfig memory cfg = reactive.getRiskConfig();
        cfg.mitigationCooldownSeconds = 0;

        vm.prank(OWNER);
        vm.expectRevert(SecurityReactive.SecurityReactive__InvalidRiskConfig.selector);
        reactive.setRiskConfig(cfg);

        vm.expectRevert(SecurityReactive.SecurityReactive__NotOwner.selector);
        reactive.setCallbackGasLimit(100_000);
    }

    function testReactIgnoresUnexpectedSourceOrTopic() public {
        IReactive.LogRecord memory wrongSource =
            _telemetryLog(address(0xDEAD), keccak256("pool"), true, 1_000, 300, 300, 300, 1_000_000, 100, 1);

        vm.recordLogs();
        reactive.react(wrongSource);
        Vm.Log[] memory entries = vm.getRecordedLogs();

        assertEq(_countTopic(entries, CALLBACK_TOPIC_0), 0);
        assertEq(_countTopic(entries, CALLBACK_QUEUED_TOPIC_0), 0);
    }

    function testQueuesCallbackForHighRiskAndDecodesPayload() public {
        bytes32 poolId = keccak256("pool-high");

        IReactive.LogRecord memory log =
            _telemetryLog(HOOK, poolId, true, 1_000, 500, 600, 9_000, 1_000_000, 100, 1);

        vm.recordLogs();
        reactive.react(log);
        Vm.Log[] memory entries = vm.getRecordedLogs();

        assertEq(_countTopic(entries, CALLBACK_QUEUED_TOPIC_0), 1);
        assertEq(_countTopic(entries, CALLBACK_TOPIC_0), 1);

        bytes memory callbackPayload = _extractCallbackPayload(entries);

        (address placeholder, bytes32 decodedPoolId, uint256 nonce, bytes memory extra) = _decodeApplyMitigation(callbackPayload);
        assertEq(placeholder, address(0));
        assertEq(decodedPoolId, poolId);
        assertEq(nonce, 1);

        (
            uint24 dynamicFeePips,
            uint16 throttleBps,
            uint128 maxTradeSize,
            uint64 pauseSeconds,
            uint16 riskScoreBps,
            uint8 mode,
            bytes32 reason
        ) = abi.decode(extra, (uint24, uint16, uint128, uint64, uint16, uint8, bytes32));

        assertGt(riskScoreBps, 6_000);
        assertEq(mode, uint8(SecurityReactive.MitigationMode.ADAPTIVE_FEE));
        assertEq(dynamicFeePips, reactive.getRiskConfig().highDynamicFeePips);
        assertEq(throttleBps, 0);
        assertEq(maxTradeSize, 0);
        assertEq(pauseSeconds, 0);
        assertEq(reason, keccak256("ELEVATED_RISK"));
    }

    function testCooldownPreventsRapidRepeatMitigation() public {
        bytes32 poolId = keccak256("pool-cooldown");

        vm.recordLogs();
        reactive.react(_telemetryLog(HOOK, poolId, true, 1_000, 500, 600, 9_000, 1_000_000, 100, 1));
        reactive.react(_telemetryLog(HOOK, poolId, false, 1_000, 500, 600, 9_000, 2_000_000, 110, 2));
        reactive.react(_telemetryLog(HOOK, poolId, true, 1_000, 500, 600, 9_000, 2_500_000, 131, 3));
        Vm.Log[] memory entries = vm.getRecordedLogs();

        assertEq(_countTopic(entries, CALLBACK_QUEUED_TOPIC_0), 2);
        assertEq(reactive.getPoolRiskState(poolId).mitigationNonce, 2);
    }

    function testDedupSkipsSameLogRecord() public {
        bytes32 poolId = keccak256("pool-dedup");
        IReactive.LogRecord memory log = _telemetryLog(HOOK, poolId, true, 1_000, 500, 600, 9_000, 1_000_000, 100, 1);

        vm.recordLogs();
        reactive.react(log);
        reactive.react(log);
        Vm.Log[] memory entries = vm.getRecordedLogs();

        assertEq(_countTopic(entries, CALLBACK_QUEUED_TOPIC_0), 1);
        assertEq(_countTopic(entries, CALLBACK_TOPIC_0), 1);
    }

    function testCriticalRiskUsesCombinedMitigationPath() public {
        SecurityReactive.RiskConfig memory cfg = reactive.getRiskConfig();
        cfg.highRiskScoreBps = 2_000;
        cfg.criticalRiskScoreBps = 7_000;
        cfg.mitigationCooldownSeconds = 1;

        vm.prank(OWNER);
        reactive.setRiskConfig(cfg);

        bytes32 poolId = keccak256("pool-critical");

        vm.recordLogs();
        reactive.react(_telemetryLog(HOOK, poolId, true, 1_500, 900, 900, 9_900, 1_000_000, 100, 1));
        Vm.Log[] memory entries = vm.getRecordedLogs();

        bytes memory callbackPayload = _extractCallbackPayload(entries);
        (, , , bytes memory extra) = _decodeApplyMitigation(callbackPayload);

        (
            uint24 dynamicFeePips,
            uint16 throttleBps,
            uint128 maxTradeSize,
            uint64 pauseSeconds,
            uint16 riskScoreBps,
            uint8 mode,
            bytes32 reason
        ) = abi.decode(extra, (uint24, uint16, uint128, uint64, uint16, uint8, bytes32));

        assertEq(mode, uint8(SecurityReactive.MitigationMode.COMBINED));
        assertEq(dynamicFeePips, cfg.criticalDynamicFeePips);
        assertEq(throttleBps, cfg.criticalThrottleBps);
        assertGt(maxTradeSize, 0);
        assertEq(pauseSeconds, cfg.criticalPauseSeconds);
        assertGe(riskScoreBps, cfg.criticalRiskScoreBps);
        assertEq(reason, keccak256("CRITICAL_RISK"));
    }

    function _telemetryLog(
        address source,
        bytes32 poolId,
        bool zeroForOne,
        uint32 rollingVolatilityBps,
        uint32 priceDeviationBps,
        uint32 slippageBps,
        uint32 liquidityImbalanceBps,
        uint128 rollingVolume,
        uint64 observedAt,
        uint256 sequence
    ) internal pure returns (IReactive.LogRecord memory) {
        return IReactive.LogRecord({
            chain_id: ORIGIN_CHAIN_ID,
            _contract: source,
            topic_0: SECURITY_TELEMETRY_TOPIC_0,
            topic_1: uint256(poolId),
            topic_2: uint256(uint160(address(0xAABBCC))),
            topic_3: 0,
            data: abi.encode(
                zeroForOne,
                int256(-1 ether),
                int24(10),
                uint160(1_250_000),
                rollingVolatilityBps,
                priceDeviationBps,
                slippageBps,
                liquidityImbalanceBps,
                rollingVolume,
                observedAt,
                uint64(sequence)
            ),
            block_number: 1,
            op_code: 0,
            block_hash: uint256(keccak256(abi.encodePacked("b", sequence))),
            tx_hash: uint256(keccak256(abi.encodePacked("t", sequence))),
            log_index: sequence
        });
    }

    function _countTopic(Vm.Log[] memory entries, bytes32 topic0) internal pure returns (uint256 count) {
        for (uint256 i = 0; i < entries.length; i++) {
            if (entries[i].topics.length > 0 && entries[i].topics[0] == topic0) {
                count += 1;
            }
        }
    }

    function _extractCallbackPayload(Vm.Log[] memory entries) internal pure returns (bytes memory callbackPayload) {
        for (uint256 i = 0; i < entries.length; i++) {
            if (entries[i].topics.length > 0 && entries[i].topics[0] == CALLBACK_TOPIC_0) {
                return abi.decode(entries[i].data, (bytes));
            }
        }
        revert("callback event not found");
    }

    function _decodeApplyMitigation(bytes memory payload)
        internal
        pure
        returns (address reactVm, bytes32 poolId, uint256 nonce, bytes memory extra)
    {
        require(payload.length >= 4, "payload too short");

        bytes memory args = new bytes(payload.length - 4);
        for (uint256 i = 4; i < payload.length; i++) {
            args[i - 4] = payload[i];
        }

        (reactVm, poolId, nonce, extra) = abi.decode(args, (address, bytes32, uint256, bytes));
    }
}
