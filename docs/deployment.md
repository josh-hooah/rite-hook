# Deployment

## Prerequisites
- Foundry
- Node.js + pnpm (frontend/shared)
- funded deployer keys
- chain addresses: `POOL_MANAGER`, `CALLBACK_PROXY`

## 1) Bootstrap + Pin Verify
```bash
./scripts/bootstrap.sh
./scripts/verify_uniswap_pin.sh
```

## 2) Local (Anvil)
```bash
make deploy-local
```

## 3) Base Sepolia (Origin + Destination Contracts)
```bash
export SEPOLIA_RPC=...
export DEPLOYER_PRIVATE_KEY=...
export OWNER=...
export POOL_MANAGER=...
export CALLBACK_PROXY=...
export VOLATILITY_WINDOW=8
export DEPLOY_INTENT_STACK=1
export HOOKMATE_ROUTER=...
export PERMIT2=...
make deploy-sepolia
```

Deployment script:
- `contracts/script/Deploy.s.sol`
- always deploys security stack
- deploys intent stack when `DEPLOY_INTENT_STACK=1` (or when both `HOOKMATE_ROUTER` and `PERMIT2` are set)

Artifacts are written under:
- `contracts/broadcast/Deploy.s.sol/<chainId>/run-latest.json`

## 4) Reactive Deployment
```bash
export REACTIVE_RPC=...
export REACTIVE_PRIVATE_KEY=...
export REACTIVE_OWNER=...
export ORIGIN_CHAIN_ID=84532
export DESTINATION_CHAIN_ID=84532
export SECURITY_HOOK=...
export SECURITY_EXECUTOR=...
export CALLBACK_GAS_LIMIT=1500000
make deploy-reactive
```

Reactive script:
- `reactive/scripts/deploy.sh`

## 5) Post-Deploy Wiring

Allowlist deployed ReactVM IDs on destination executors:

```bash
cast send <SECURITY_EXECUTOR> "setReactVM(address,bool)" <REACT_VM_SECURITY> true --rpc-url <SEPOLIA_RPC> --private-key <PK>
cast send <INTENT_EXECUTOR> "setReactVM(address,bool)" <REACT_VM_INTENT> true --rpc-url <SEPOLIA_RPC> --private-key <PK>
```

Set callback proxy if needed:

```bash
cast send <SECURITY_EXECUTOR> "setCallbackProxy(address)" <CALLBACK_PROXY> --rpc-url <SEPOLIA_RPC> --private-key <PK>
cast send <INTENT_EXECUTOR> "setCallbackProxy(address)" <CALLBACK_PROXY> --rpc-url <SEPOLIA_RPC> --private-key <PK>
```

## Notes
- callback payload arg0 is emitted as `address(0)` and overwritten with ReactVM ID by Reactive infrastructure
- transfer ownership to multisig prior to production
- tune per-pool risk/trigger thresholds before enabling significant TVL
