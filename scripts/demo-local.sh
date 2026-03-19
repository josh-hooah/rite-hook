#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

phase() {
  echo
  echo "============================================================"
  echo "[demo-local] PHASE: $*"
  echo "============================================================"
}

log() {
  echo "[demo-local] $*"
}

phase "RITE workflow map"
cat <<'MAP'
Intent path:
1) User creates intent in IntentExecutor.
2) IntentHook emits SwapTelemetry.
3) IntentReactive evaluates deterministic trigger conditions.
4) Callback payload targets executeIntent(reactVM,...).
5) IntentExecutor authenticates callback, validates nonce/trigger, executes/cancels/refunds.

Security path:
1) Toxic swap hits SecurityHook and emits SecurityTelemetry.
2) SecurityReactive scores telemetry (price/volume/slippage/imbalance/temporal/MEV).
3) SecurityReactive emits mitigation callback payload to SecurityExecutor.
4) SecurityExecutor authenticates callback proxy + ReactVM and validates nonce.
5) SecurityHook enforces mitigation (dynamic fee / throttle / pause) for LP protection.
MAP

phase "Intent lifecycle integration proof"
(
  cd "$ROOT_DIR/contracts"
  FOUNDRY_OFFLINE=true forge test --match-path test/integration/IntentLifecycle.t.sol -vv
)

phase "Intent reactive trigger proof"
(
  cd "$ROOT_DIR/reactive"
  FOUNDRY_OFFLINE=true forge test --match-path test/IntentReactive.t.sol -vv
)

phase "Security lifecycle integration proof"
(
  cd "$ROOT_DIR/contracts"
  FOUNDRY_OFFLINE=true forge test --match-path test/integration/SecurityLifecycle.t.sol -vv
)

phase "Security reactive risk engine proof"
(
  cd "$ROOT_DIR/reactive"
  FOUNDRY_OFFLINE=true forge test --match-path test/SecurityReactive.t.sol -vv
)

phase "Assertions proven"
log "Intent trigger path simulated"
log "Intent callback auth + nonce handling enforced"
log "Intent execution/cancel/refund lifecycle validated"
log "Attack scenario simulated"
log "Deterministic risk score computed"
log "Mitigation callback payload emitted"
log "Executor auth checks + nonce checks enforced"
log "Hook protection state blocks/controls risky swaps"

LOCAL_BROADCAST="$ROOT_DIR/contracts/broadcast/Deploy.s.sol/31337/run-latest.json"
if [[ -f "$LOCAL_BROADCAST" ]] && command -v jq >/dev/null 2>&1; then
  phase "Latest local deployment artifact"
  jq -r '
    "[demo-local] broadcast: " + (input_filename),
    "[demo-local] contracts:",
    (.transactions[] | select(.contractName != null and .contractAddress != null) | "  - " + .contractName + ": " + .contractAddress),
    "[demo-local] tx hashes:",
    (.receipts[]? | "  - " + .transactionHash)
  ' "$LOCAL_BROADCAST" || true
fi
