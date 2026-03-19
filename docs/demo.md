# Demo Runbook

## Local Demo
```bash
make demo-local
```

What it proves:

Intent lifecycle:
- create -> trigger evaluation -> callback-auth execution path
- nonce handling and deterministic execution outcomes

Security lifecycle:
- detection -> risk scoring -> mitigation callback -> hook enforcement
- callback authenticity and replay-safe handling

## Base Sepolia + Lasna Demo
```bash
make demo-sepolia
```

Required env:

- `SEPOLIA_RPC`
- `DEPLOYER_PRIVATE_KEY`
- `OWNER`
- `POOL_MANAGER`
- `CALLBACK_PROXY`

Optional reactive deployment in same run:

- `REACTIVE_RPC`
- `REACTIVE_PRIVATE_KEY`
- `REACTIVE_OWNER`

Optional intent proof simulation in same run:

- `RUN_INTENT_PROOF=1` (requires intent stack deployed)

Output includes:

- deployed `SecurityHook` and `SecurityExecutor` addresses
- transaction hashes for deployment and mitigation simulation
- explorer links for every tx

Explorer formats:

- `https://sepolia.basescan.org/tx/<txid>`
- `https://lasna.reactscan.net/tx/<txid>`

## Attack + Intent Simulation Coverage
Current scripted flow guarantees:
1. intent callback execution path proof (local)
2. mitigation callback/auth + nonce path proof (local and sepolia)

## Troubleshooting
- pin mismatch: rerun `./scripts/bootstrap.sh`
- missing tx hashes: confirm broadcast JSON has receipts
- reactive skipped: verify `REACTIVE_RPC` and `REACTIVE_PRIVATE_KEY`
