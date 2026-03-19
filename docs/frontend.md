# Frontend

## Stack
- React + TypeScript + Vite
- shared package: `@rite/shared`

## Purpose
Unified RITE dashboard for:

- intent lifecycle visibility (`IntentCreated`, `IntentExecuted`, `IntentCancelled`, `ExecutionFailed`)
- intent hook telemetry snapshots (`SwapTelemetry`)
- security telemetry from `SecurityHook`
- mitigation outcomes from `SecurityExecutor`

## Environment
`frontend/.env.example`:

- `VITE_CHAIN_ID`
- `VITE_INTENT_HOOK`
- `VITE_INTENT_EXECUTOR`
- `VITE_SECURITY_HOOK`
- `VITE_SECURITY_EXECUTOR`

Legacy fallbacks still supported:

- `VITE_HOOK_ADDRESS`
- `VITE_EXECUTOR_ADDRESS`

## Run
```bash
cd frontend
pnpm install
pnpm dev
```

## Build
```bash
cd frontend
pnpm install
pnpm build
```

## Data Sources
The UI reads logs via wallet-provider `eth_getLogs` for:

Intent domain:
- `SwapTelemetry`
- `IntentCreated`
- `IntentExecuted`
- `IntentCancelled`
- `ExecutionFailed`

Security domain:
- `SecurityTelemetry`
- `ProtectionApplied`
- `MitigationAccepted`
- `MitigationRejected`

The dashboard derives:
- intent trigger/settlement activity snapshots
- execution outcome timeline
- risk and mitigation timeline
