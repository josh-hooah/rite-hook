# Overview

RITE Hook is a production-oriented execution and protection layer for Uniswap v4.

RITE coordinates two pipelines:

- intent pipeline: deterministic trigger-based execution
- security pipeline: deterministic risk scoring and mitigation enforcement

## Integrations
![Uniswap v4](../assets/uniswap-v4-mark.svg)
![Reactive](../assets/reactive-mark.svg)

## Core Components
Intent domain:
- `contracts/src/IntentHook.sol`
- `contracts/src/IntentExecutor.sol`
- `contracts/src/adapters/HookmateV4SwapAdapter.sol`
- `reactive/src/IntentReactive.sol`

Security domain:
- `contracts/src/SecurityHook.sol`
- `contracts/src/SecurityExecutor.sol`
- `reactive/src/SecurityReactive.sol`

Shared/frontend:
- `contracts/src/libraries/*`
- `frontend/src/App.tsx`
- `shared/src/*`

## Lifecycle Summary
Intent:
1. user creates intent in `IntentExecutor`
2. `IntentHook` emits telemetry on swap activity
3. `IntentReactive` evaluates trigger conditions
4. callback proxy calls `IntentExecutor.executeIntent(...)`
5. executor validates auth/nonce/trigger and settles via adapter

Security:
1. `SecurityHook` emits `SecurityTelemetry`
2. `SecurityReactive` computes risk score + mitigation payload
3. callback proxy calls `SecurityExecutor.applyMitigation(...)`
4. executor validates sender/reactVM/nonce
5. hook applies protection and enforces it during `beforeSwap`

## Repository Domains
- `contracts/`: origin + destination solidity components and tests
- `reactive/`: Reactive trigger/risk engines and tests
- `frontend/`: operator dashboard for intent + security signals
- `shared/`: shared ABIs/types/constants for TS packages
- `scripts/`: bootstrap, pin verification, deployment, demo, coverage gates
