# API

## Intent Layer

### `IntentHook`
Path: `contracts/src/IntentHook.sol`

State-changing:
- `setVolatilityWindow(uint32)`

Views:
- `volatilityWindow()`
- `telemetryByPoolKey(PoolKey)`
- `telemetryByPoolId(bytes32)`

Events:
- `BeforeSwapObserved(...)`
- `SwapTelemetry(...)`
- `HookConfigured(uint32)`

### `IntentExecutor`
Path: `contracts/src/IntentExecutor.sol`

State-changing:
- `setCallbackProxy(address)`
- `setReactVM(address,bool)`
- `setSwapAdapter(IIntentSwapAdapter)`
- `createIntent(IntentParams)`
- `updateIntent(bytes32,uint256,uint64,TriggerConfig)`
- `cancelIntent(bytes32)`
- `executeIntent(address,bytes32,uint256,bytes)`

Views:
- `callbackProxy()`
- `swapAdapter()`
- `reactVMAllowlist(address)`
- `userIntentCount(address)`
- `getIntent(bytes32)`
- `lastExecution(bytes32)`

Events:
- `IntentCreated(...)`
- `IntentUpdated(...)`
- `IntentCancelled(...)`
- `IntentExecutable(...)`
- `IntentExecuted(...)`
- `ExecutionFailed(...)`
- `CallbackProxyUpdated(address)`
- `ReactVMAllowlistUpdated(address,bool)`
- `SwapAdapterUpdated(address)`

### `HookmateV4SwapAdapter`
Path: `contracts/src/adapters/HookmateV4SwapAdapter.sol`

Core:
- `executeSwap(SwapRequest)`

## Security Layer

### `SecurityHook`
Path: `contracts/src/SecurityHook.sol`

State-changing:
- `setSecurityExecutor(address)`
- `setVolatilityWindow(uint32)`
- `setPoolProtectionConfig(bytes32,ProtectionConfig)`
- `applyProtection(bytes32,uint256,MitigationPayload)`

Views:
- `telemetryByPoolId(bytes32)`
- `telemetryByPoolKey(PoolKey)`
- `protectionStateByPoolId(bytes32)`
- `protectionConfigByPoolId(bytes32)`

Events:
- `SecurityTelemetry(...)`
- `ProtectionApplied(...)`
- `PoolProtectionConfigUpdated(...)`
- `SecurityExecutorUpdated(address)`
- `VolatilityWindowUpdated(uint32)`

### `SecurityExecutor`
Path: `contracts/src/SecurityExecutor.sol`

State-changing:
- `setCallbackProxy(address)`
- `setReactVM(address,bool)`
- `setSecurityHook(ISecurityHook)`
- `applyMitigation(address,bytes32,uint256,bytes)`

Views:
- `callbackProxy()`
- `securityHook()`
- `reactVMAllowlist(address)`
- `lastMitigationNonce(bytes32)`

Events:
- `MitigationAccepted(...)`
- `MitigationRejected(...)`
- `CallbackProxyUpdated(address)`
- `ReactVMAllowlistUpdated(address,bool)`
- `SecurityHookUpdated(address)`

## Reactive Layer

### `IntentReactive`
Path: `reactive/src/IntentReactive.sol`

State-changing:
- `setCallbackGasLimit(uint64)`
- `setDispatchRetryInterval(uint64)`
- `react(LogRecord)`

Views:
- `trackedIntents(bytes32)`
- `lastDispatchedNonce(bytes32)`
- `processedLogs(bytes32)`

Events:
- `IntentTracked(...)`
- `IntentDeactivated(...)`
- `CallbackQueued(...)`
- inherited `Callback(...)`

### `SecurityReactive`
Path: `reactive/src/SecurityReactive.sol`

State-changing:
- `setCallbackGasLimit(uint64)`
- `setRiskConfig(RiskConfig)`
- `react(LogRecord)`

Views:
- `getRiskConfig()`
- `getPoolRiskState(bytes32)`
- `callbackGasLimit()`
- `processedLogs(bytes32)`

Events:
- `RiskScored(...)`
- `CallbackQueued(...)`
- `RiskConfigUpdated(RiskConfig)`
- `CallbackGasLimitUpdated(uint64)`
- inherited `Callback(...)`

## Callback Payload Schemas

Intent callback target:
- `executeIntent(address reactVM, bytes32 intentId, uint256 nonce, bytes extra)`

Security callback target:
- `applyMitigation(address reactVM, bytes32 poolId, uint256 nonce, bytes extra)`

Important behavior:
- callback payload arg0 is emitted as placeholder (`address(0)`) by Reactive contracts
- infrastructure overwrites arg0 with the ReactVM ID before destination execution
