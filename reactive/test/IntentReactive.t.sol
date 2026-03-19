// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {IntentReactive} from "../src/IntentReactive.sol";
import {IReactive} from "../src/lib/ReactiveBase.sol";

contract IntentReactiveUnitTest is Test {
    struct TriggerConfigDecoded {
        uint160 targetSqrtPriceX96;
        bool priceAbove;
        uint64 startTime;
        uint64 endTime;
        uint64 interval;
        uint32 volatilityBps;
        bool volatilityAbove;
        uint16 chunkBips;
    }

    IntentReactive internal reactive;

    address internal constant OWNER = address(0xA11CE);
    address internal constant HOOK = address(0x1001);
    address internal constant EXECUTOR = address(0x1002);
    uint256 internal constant ORIGIN_CHAIN_ID = 11155111;
    uint256 internal constant DESTINATION_CHAIN_ID = 84532;

    uint256 internal constant INTENT_CREATED_TOPIC_0 =
        uint256(keccak256("IntentCreated(bytes32,address,bytes32,uint8,bytes,uint64,uint256,bool,uint256,uint256)"));
    uint256 internal constant INTENT_CANCELLED_TOPIC_0 = uint256(keccak256("IntentCancelled(bytes32,address,bytes32,uint256)"));
    uint256 internal constant INTENT_EXECUTED_TOPIC_0 = uint256(keccak256("IntentExecuted(bytes32,uint256,uint256,uint256,bool)"));
    uint256 internal constant SWAP_TELEMETRY_TOPIC_0 =
        uint256(keccak256("SwapTelemetry(bytes32,address,int24,uint160,uint32,int128,int128,uint64)"));
    bytes32 internal constant CALLBACK_QUEUED_TOPIC_0 = keccak256("CallbackQueued(bytes32,uint256,bytes32)");

    function setUp() public {
        reactive = new IntentReactive(
            OWNER, ORIGIN_CHAIN_ID, DESTINATION_CHAIN_ID, HOOK, EXECUTOR, /* callbackGasLimit */ 1_500_000
        );
    }

    function testConstructorRejectsInvalidConfig() public {
        vm.expectRevert(IntentReactive.InvalidConfig.selector);
        new IntentReactive(address(0), ORIGIN_CHAIN_ID, DESTINATION_CHAIN_ID, HOOK, EXECUTOR, 1_500_000);

        vm.expectRevert(IntentReactive.InvalidConfig.selector);
        new IntentReactive(OWNER, ORIGIN_CHAIN_ID, DESTINATION_CHAIN_ID, address(0), EXECUTOR, 1_500_000);

        vm.expectRevert(IntentReactive.InvalidConfig.selector);
        new IntentReactive(OWNER, ORIGIN_CHAIN_ID, DESTINATION_CHAIN_ID, HOOK, address(0), 1_500_000);

        vm.expectRevert(IntentReactive.InvalidConfig.selector);
        new IntentReactive(OWNER, ORIGIN_CHAIN_ID, DESTINATION_CHAIN_ID, HOOK, EXECUTOR, 0);
    }

    function testOwnerSettersValidateAccessAndBounds() public {
        vm.prank(OWNER);
        reactive.setCallbackGasLimit(2_000_000);
        assertEq(reactive.callbackGasLimit(), 2_000_000);

        vm.prank(OWNER);
        reactive.setDispatchRetryInterval(45);
        assertEq(reactive.dispatchRetryInterval(), 45);

        vm.prank(OWNER);
        vm.expectRevert(IntentReactive.InvalidRetryInterval.selector);
        reactive.setDispatchRetryInterval(0);

        vm.expectRevert(IntentReactive.NotOwner.selector);
        reactive.setDispatchRetryInterval(10);
    }

    function testReactIgnoresUnexpectedSourceContracts() public {
        bytes32 intentId = keccak256("intent");
        bytes32 poolId = keccak256("pool");

        IReactive.LogRecord memory forgedCreate = _buildIntentCreatedLog(
            address(0xDEAD), intentId, poolId, 1, _priceTrigger(10, true), uint64(block.timestamp + 1 days), 0, 1
        );
        reactive.react(forgedCreate);

        assertFalse(_isIntentActive(intentId));

        IReactive.LogRecord memory forgedTelemetry = _buildSwapTelemetryLog(
            address(0xDEAD), poolId, 0, 100, 5, 0, 0, uint64(block.timestamp), 2
        );
        reactive.react(forgedTelemetry);
        assertEq(reactive.lastDispatchedNonce(intentId), 0);
    }

    function testTracksIntentAndQueuesCallbackOnTelemetry() public {
        bytes32 intentId = keccak256("intent-price");
        bytes32 poolId = keccak256("pool-price");

        IReactive.LogRecord memory createLog = _buildIntentCreatedLog(
            EXECUTOR, intentId, poolId, 0, _priceTrigger(100, true), uint64(block.timestamp + 1 days), 0, 1
        );
        reactive.react(createLog);

        assertTrue(_isIntentActive(intentId));
        assertEq(_intentNonce(intentId), 0);

        IReactive.LogRecord memory telemetryLog =
            _buildSwapTelemetryLog(HOOK, poolId, 0, 120, 10, -10, 10, uint64(block.timestamp + 5), 2);

        vm.recordLogs();
        reactive.react(telemetryLog);
        Vm.Log[] memory entries = vm.getRecordedLogs();

        uint256 callbackQueuedCount;
        for (uint256 i = 0; i < entries.length; i++) {
            if (entries[i].topics.length > 0 && entries[i].topics[0] == CALLBACK_QUEUED_TOPIC_0) {
                callbackQueuedCount += 1;
            }
        }

        assertEq(callbackQueuedCount, 1);
        assertEq(reactive.lastDispatchedNonce(intentId), 0);
    }

    function testProcessedLogDedupPreventsDuplicateCallbackQueue() public {
        bytes32 intentId = keccak256("intent-dedup");
        bytes32 poolId = keccak256("pool-dedup");

        reactive.react(
            _buildIntentCreatedLog(EXECUTOR, intentId, poolId, 0, _priceTrigger(1, true), uint64(block.timestamp + 1 days), 0, 1)
        );

        IReactive.LogRecord memory telemetryLog =
            _buildSwapTelemetryLog(HOOK, poolId, 0, 2, 5, -1, 1, uint64(block.timestamp + 10), 2);

        vm.recordLogs();
        reactive.react(telemetryLog);
        reactive.react(telemetryLog);
        Vm.Log[] memory entries = vm.getRecordedLogs();

        uint256 callbackQueuedCount;
        for (uint256 i = 0; i < entries.length; i++) {
            if (entries[i].topics.length > 0 && entries[i].topics[0] == CALLBACK_QUEUED_TOPIC_0) {
                callbackQueuedCount += 1;
            }
        }

        assertEq(callbackQueuedCount, 1);
    }

    function testExecutedLogDoesNotRollbackNonce() public {
        bytes32 intentId = keccak256("intent-nonce");
        bytes32 poolId = keccak256("pool-nonce");

        reactive.react(
            _buildIntentCreatedLog(EXECUTOR, intentId, poolId, 0, _priceTrigger(1, true), uint64(block.timestamp + 1 days), 0, 1)
        );

        reactive.react(_buildIntentExecutedLog(EXECUTOR, intentId, 4, false, 2));
        assertEq(_intentNonce(intentId), 5);

        reactive.react(_buildIntentExecutedLog(EXECUTOR, intentId, 1, false, 3));
        assertEq(_intentNonce(intentId), 5);
    }

    function testRetryIntervalAllowsRedispatchForSameNonce() public {
        bytes32 intentId = keccak256("intent-retry");
        bytes32 poolId = keccak256("pool-retry");

        reactive.react(
            _buildIntentCreatedLog(EXECUTOR, intentId, poolId, 0, _priceTrigger(100, true), uint64(block.timestamp + 1 days), 0, 1)
        );

        IReactive.LogRecord memory first = _buildSwapTelemetryLog(HOOK, poolId, 0, 150, 10, 0, 0, 100, 2);
        IReactive.LogRecord memory second = _buildSwapTelemetryLog(HOOK, poolId, 0, 150, 10, 0, 0, 110, 3);
        IReactive.LogRecord memory third = _buildSwapTelemetryLog(HOOK, poolId, 0, 150, 10, 0, 0, 131, 4);

        vm.recordLogs();
        reactive.react(first);
        reactive.react(second);
        reactive.react(third);
        Vm.Log[] memory entries = vm.getRecordedLogs();

        uint256 callbackQueuedCount;
        for (uint256 i = 0; i < entries.length; i++) {
            if (entries[i].topics.length > 0 && entries[i].topics[0] == CALLBACK_QUEUED_TOPIC_0) {
                callbackQueuedCount += 1;
            }
        }

        assertEq(callbackQueuedCount, 2);
        assertEq(reactive.lastDispatchedNonce(intentId), 0);
    }

    function _isIntentActive(bytes32 intentId) internal view returns (bool active) {
        (, , , , , , , , , , , , , active) = reactive.trackedIntents(intentId);
    }

    function _intentNonce(bytes32 intentId) internal view returns (uint256 nonce) {
        (, , , , , , , , , , , nonce, , ) = reactive.trackedIntents(intentId);
    }

    function _priceTrigger(uint160 target, bool priceAbove) internal pure returns (bytes memory) {
        TriggerConfigDecoded memory trigger = TriggerConfigDecoded({
            targetSqrtPriceX96: target,
            priceAbove: priceAbove,
            startTime: 0,
            endTime: 0,
            interval: 0,
            volatilityBps: 0,
            volatilityAbove: false,
            chunkBips: 10_000
        });

        return abi.encode(trigger);
    }

    function _buildIntentCreatedLog(
        address source,
        bytes32 intentId,
        bytes32 poolId,
        uint8 triggerType,
        bytes memory triggerConfigEncoded,
        uint64 expiry,
        uint256 nonce,
        uint256 sequence
    ) internal pure returns (IReactive.LogRecord memory) {
        return IReactive.LogRecord({
            chain_id: ORIGIN_CHAIN_ID,
            _contract: source,
            topic_0: INTENT_CREATED_TOPIC_0,
            topic_1: uint256(intentId),
            topic_2: uint256(uint160(address(0xAAAA))),
            topic_3: uint256(poolId),
            data: abi.encode(triggerType, triggerConfigEncoded, expiry, nonce, true, uint256(1 ether), uint256(1 ether)),
            block_number: 1,
            op_code: 0,
            block_hash: uint256(keccak256(abi.encodePacked("b", sequence))),
            tx_hash: uint256(keccak256(abi.encodePacked("t", sequence))),
            log_index: sequence
        });
    }

    function _buildSwapTelemetryLog(
        address source,
        bytes32 poolId,
        int24 tick,
        uint160 sqrtPriceX96,
        uint32 rollingVolatilityBps,
        int128 amount0Delta,
        int128 amount1Delta,
        uint64 observedAt,
        uint256 sequence
    ) internal pure returns (IReactive.LogRecord memory) {
        return IReactive.LogRecord({
            chain_id: ORIGIN_CHAIN_ID,
            _contract: source,
            topic_0: SWAP_TELEMETRY_TOPIC_0,
            topic_1: uint256(poolId),
            topic_2: uint256(uint160(address(0xBBBB))),
            topic_3: 0,
            data: abi.encode(tick, sqrtPriceX96, rollingVolatilityBps, amount0Delta, amount1Delta, observedAt),
            block_number: 1,
            op_code: 0,
            block_hash: uint256(keccak256(abi.encodePacked("b", sequence))),
            tx_hash: uint256(keccak256(abi.encodePacked("t", sequence))),
            log_index: sequence
        });
    }

    function _buildIntentExecutedLog(address source, bytes32 intentId, uint256 nonce, bool fullyExecuted, uint256 sequence)
        internal
        pure
        returns (IReactive.LogRecord memory)
    {
        return IReactive.LogRecord({
            chain_id: ORIGIN_CHAIN_ID,
            _contract: source,
            topic_0: INTENT_EXECUTED_TOPIC_0,
            topic_1: uint256(intentId),
            topic_2: nonce,
            topic_3: 0,
            data: abi.encode(uint256(1 ether), uint256(1 ether), fullyExecuted),
            block_number: 1,
            op_code: 0,
            block_hash: uint256(keccak256(abi.encodePacked("b", sequence))),
            tx_hash: uint256(keccak256(abi.encodePacked("t", sequence))),
            log_index: sequence
        });
    }
}
