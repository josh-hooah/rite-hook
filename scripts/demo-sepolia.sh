#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="$ROOT_DIR/.env"
if [[ -f "$ENV_FILE" ]]; then
  # shellcheck disable=SC1090
  set -a && source "$ENV_FILE" && set +a
fi

log() {
  echo "[demo] $*"
}

warn() {
  echo "[demo][warn] $*" >&2
}

phase() {
  echo
  echo "============================================================"
  echo "[demo] PHASE: $*"
  echo "============================================================"
}

require_cmd() {
  local cmd="$1"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "[demo] missing required command: $cmd" >&2
    exit 1
  fi
}

update_env() {
  local key="$1"
  local value="$2"
  local tmp
  tmp="$(mktemp)"

  if [[ ! -f "$ENV_FILE" ]]; then
    touch "$ENV_FILE"
  fi

  awk -v k="$key" -v v="$value" '
    BEGIN { done = 0 }
    $0 ~ ("^" k "=") { print k "=" v; done = 1; next }
    { print }
    END { if (!done) print k "=" v }
  ' "$ENV_FILE" >"$tmp"
  mv "$tmp" "$ENV_FILE"
}

extract_tx_hash() {
  local payload="$1"
  local hash
  hash="$(printf '%s\n' "$payload" | sed -nE 's/.*[Tt]ransaction hash:[[:space:]]*(0x[0-9a-fA-F]{64}).*/\1/p' | tail -n1)"
  if [[ -z "$hash" ]]; then
    hash="$(printf '%s\n' "$payload" | sed -nE 's/^[[:space:]]*transactionHash[[:space:]]+(0x[0-9a-fA-F]{64}).*/\1/p' | tail -n1)"
  fi
  echo "$hash"
}

print_tx() {
  local label="$1"
  local hash="$2"
  local explorer_base="$3"
  if [[ -z "$hash" ]]; then
    return
  fi

  log "Tx: $label"
  echo "TxHash: $hash"
  if [[ -n "$explorer_base" ]]; then
    echo "URL: ${explorer_base%/}/tx/$hash"
  fi
}

code_exists() {
  local address="$1"
  local rpc="$2"
  if [[ -z "$address" || "$address" == "null" ]]; then
    return 1
  fi

  local code
  code="$(cast code "$address" --rpc-url "$rpc" 2>/dev/null || true)"
  [[ -n "$code" && "$code" != "0x" ]]
}

join_csv() {
  local IFS=,
  echo "$*"
}

require_cmd forge
require_cmd cast
require_cmd jq

HAS_REACTIVE=0
if [[ -f "$ROOT_DIR/reactive/src/SecurityReactive.sol" && -f "$ROOT_DIR/reactive/src/IntentReactive.sol" ]]; then
  HAS_REACTIVE=1
fi

SEPOLIA_RPC="${SEPOLIA_RPC:-${SEPOLIA_RPC_URL:-}}"
DEPLOYER_PRIVATE_KEY="${DEPLOYER_PRIVATE_KEY:-${SEPOLIA_PRIVATE_KEY:-}}"
OWNER="${OWNER:-${OWNER_ADDRESS:-}}"
POOL_MANAGER="${POOL_MANAGER:-${POOL_MANAGER_ADDRESS:-}}"
CALLBACK_PROXY="${CALLBACK_PROXY:-${CALLBACK_PROXY_ADDRESS:-}}"
VOLATILITY_WINDOW="${VOLATILITY_WINDOW:-8}"

: "${SEPOLIA_RPC:?SEPOLIA_RPC/SEPOLIA_RPC_URL is required}"
: "${DEPLOYER_PRIVATE_KEY:?DEPLOYER_PRIVATE_KEY/SEPOLIA_PRIVATE_KEY is required}"
: "${OWNER:?OWNER/OWNER_ADDRESS is required}"
: "${POOL_MANAGER:?POOL_MANAGER/POOL_MANAGER_ADDRESS is required}"
: "${CALLBACK_PROXY:?CALLBACK_PROXY/CALLBACK_PROXY_ADDRESS is required}"

ORIGIN_EXPLORER_BASE="${ORIGIN_EXPLORER_BASE:-https://sepolia.uniscan.xyz}"
REACTIVE_EXPLORER_BASE="${REACTIVE_EXPLORER_BASE:-https://lasna.reactscan.net}"

SECURITY_HOOK="${SECURITY_HOOK:-${ORIGIN_HOOK:-}}"
SECURITY_EXECUTOR="${SECURITY_EXECUTOR:-${DESTINATION_EXECUTOR:-}}"
SECURITY_REACTIVE="${SECURITY_REACTIVE:-${REACTIVE_SECURITY_CONTRACT:-${REACTIVE_INTENT_CONTRACT:-}}}"
REACTIVE_DEPLOY_TX_HASH="${REACTIVE_DEPLOY_TX_HASH:-}"

INTENT_HOOK="${INTENT_HOOK:-${ORIGIN_INTENT_HOOK:-}}"
INTENT_EXECUTOR="${INTENT_EXECUTOR:-${DESTINATION_INTENT_EXECUTOR:-}}"
INTENT_ADAPTER="${INTENT_ADAPTER:-${INTENT_SWAP_ADAPTER:-}}"

REACTIVE_RPC="${REACTIVE_RPC:-${REACTIVE_RPC_URL:-}}"
REACTIVE_PRIVATE_KEY="${REACTIVE_PRIVATE_KEY:-}"
REACTIVE_OWNER="${REACTIVE_OWNER:-${OWNER_ADDRESS:-$OWNER}}"

ORIGIN_CHAIN_ID="${ORIGIN_CHAIN_ID:-1301}"
DESTINATION_CHAIN_ID="${DESTINATION_CHAIN_ID:-1301}"
CALLBACK_GAS_LIMIT="${CALLBACK_GAS_LIMIT:-1500000}"

HOOKMATE_ROUTER="${HOOKMATE_ROUTER:-${V4_ROUTER:-${UNIVERSAL_ROUTER_ADDRESS:-}}}"
PERMIT2="${PERMIT2:-${PERMIT2_ADDRESS:-}}"
DEPLOY_INTENT_STACK="${DEPLOY_INTENT_STACK:-1}"
RUN_INTENT_PROOF="${RUN_INTENT_PROOF:-1}"
RUN_COVERAGE_CHECK="${RUN_COVERAGE_CHECK:-1}"

CHAIN_ID="${CHAIN_ID:-}"
if [[ -z "$CHAIN_ID" ]]; then
  CHAIN_ID="$(cast chain-id --rpc-url "$SEPOLIA_RPC" 2>/dev/null || echo "1301")"
fi

phase "Project integration checks"
if [[ "$HAS_REACTIVE" == "1" ]]; then
  log "Reactive integration detected in codebase: YES"
else
  log "Reactive integration detected in codebase: NO"
  REACTIVE_RPC=""
  REACTIVE_PRIVATE_KEY=""
fi

phase "Workflow map (user + protocol perspective)"
cat <<'MAP'
User perspective:
1) User creates deterministic intent (price/time/volatility trigger).
2) User waits while onchain telemetry is emitted by hooks.
3) User observes execution/cancel outcome and receives funds/settlement.

Protocol perspective (Intent path):
1) IntentHook emits SwapTelemetry.
2) IntentReactive evaluates trigger rules in react(LogRecord).
3) Callback proxy forwards executeIntent(reactVM,...).
4) IntentExecutor authenticates callbackProxy + reactVM, checks nonce/replay/expiry, executes or rejects idempotently.

Protocol perspective (Security path):
1) SecurityHook emits SecurityTelemetry.
2) SecurityReactive computes deterministic risk score and mitigation payload.
3) Callback proxy forwards applyMitigation(reactVM,...).
4) SecurityExecutor authenticates callbackProxy + reactVM + nonce and applies protection.
5) SecurityHook enforces fee/throttle/pause during beforeSwap.
MAP

phase "Preflight"
DEPLOYER_ADDRESS="$(cast wallet address --private-key "$DEPLOYER_PRIVATE_KEY")"
log "Chain ID: $CHAIN_ID"
log "Deployer: $DEPLOYER_ADDRESS"
log "Owner: $OWNER"
log "PoolManager: $POOL_MANAGER"
log "CallbackProxy: $CALLBACK_PROXY"
log "Origin explorer: $ORIGIN_EXPLORER_BASE"
log "Reactive explorer: $REACTIVE_EXPLORER_BASE"

phase "Coverage gate (forge coverage == 100%)"
if [[ "$RUN_COVERAGE_CHECK" == "1" ]]; then
  coverage_log="$(mktemp)"
  if ! (cd "$ROOT_DIR/contracts" && FOUNDRY_OFFLINE=true forge coverage --report lcov --no-match-path 'test/invariant/*' >"$coverage_log" 2>&1); then
    tail -n 80 "$coverage_log" >&2
    echo "[demo] coverage command failed" >&2
    exit 1
  fi
  tail -n 20 "$coverage_log"
  rm -f "$coverage_log"
  (cd "$ROOT_DIR" && ./scripts/check_coverage.sh contracts/lcov.info)
else
  log "Skipping coverage check (RUN_COVERAGE_CHECK=$RUN_COVERAGE_CHECK)"
fi

if [[ "$DEPLOY_INTENT_STACK" != "1" && -n "$HOOKMATE_ROUTER" && -n "$PERMIT2" ]]; then
  DEPLOY_INTENT_STACK=1
  log "Auto-enabling intent deployment because router+permit2 are configured."
fi

phase "Deploy or reuse origin contracts"
export DEPLOYER_PRIVATE_KEY OWNER POOL_MANAGER CALLBACK_PROXY VOLATILITY_WINDOW HOOKMATE_ROUTER PERMIT2 DEPLOY_INTENT_STACK

need_origin_deploy=0
if ! code_exists "$SECURITY_HOOK" "$SEPOLIA_RPC" || ! code_exists "$SECURITY_EXECUTOR" "$SEPOLIA_RPC"; then
  need_origin_deploy=1
fi
if [[ "$DEPLOY_INTENT_STACK" == "1" ]]; then
  if ! code_exists "$INTENT_HOOK" "$SEPOLIA_RPC" || ! code_exists "$INTENT_EXECUTOR" "$SEPOLIA_RPC"; then
    need_origin_deploy=1
  fi
fi
if [[ "${FORCE_DEPLOY:-0}" == "1" ]]; then
  need_origin_deploy=1
fi

origin_txs=()
if [[ "$need_origin_deploy" == "1" ]]; then
  (
    cd "$ROOT_DIR/contracts"
    forge script script/Deploy.s.sol --rpc-url "$SEPOLIA_RPC" --private-key "$DEPLOYER_PRIVATE_KEY" --broadcast --slow -vv
  )

  ORIGIN_BROADCAST="$ROOT_DIR/contracts/broadcast/Deploy.s.sol/$CHAIN_ID/run-latest.json"
  if [[ ! -f "$ORIGIN_BROADCAST" ]]; then
    echo "[demo] missing broadcast file: $ORIGIN_BROADCAST" >&2
    exit 1
  fi

  SECURITY_HOOK="$(jq -r '.transactions[] | select(.contractName=="SecurityHook" and .contractAddress != null) | .contractAddress' "$ORIGIN_BROADCAST" | tail -n1)"
  SECURITY_EXECUTOR="$(jq -r '.transactions[] | select(.contractName=="SecurityExecutor" and .contractAddress != null) | .contractAddress' "$ORIGIN_BROADCAST" | tail -n1)"
  INTENT_HOOK="$(jq -r '.transactions[] | select(.contractName=="IntentHook" and .contractAddress != null) | .contractAddress' "$ORIGIN_BROADCAST" | tail -n1)"
  INTENT_EXECUTOR="$(jq -r '.transactions[] | select(.contractName=="IntentExecutor" and .contractAddress != null) | .contractAddress' "$ORIGIN_BROADCAST" | tail -n1)"
  INTENT_ADAPTER="$(jq -r '.transactions[] | select(.contractName=="HookmateV4SwapAdapter" and .contractAddress != null) | .contractAddress' "$ORIGIN_BROADCAST" | tail -n1)"

  while IFS= read -r tx; do
    [[ -z "$tx" ]] && continue
    origin_txs+=("$tx")
  done < <(jq -r '.receipts[]?.transactionHash // empty' "$ORIGIN_BROADCAST")

  idx=1
  for tx in "${origin_txs[@]}"; do
    print_tx "Origin Deployment #$idx" "$tx" "$ORIGIN_EXPLORER_BASE"
    idx=$((idx + 1))
  done
else
  log "Reusing existing origin deployments from .env (or environment)."
fi

if [[ -z "$SECURITY_HOOK" || -z "$SECURITY_EXECUTOR" || "$SECURITY_HOOK" == "null" || "$SECURITY_EXECUTOR" == "null" ]]; then
  echo "[demo] security contract addresses are missing" >&2
  exit 1
fi

update_env SECURITY_HOOK "$SECURITY_HOOK"
update_env SECURITY_EXECUTOR "$SECURITY_EXECUTOR"
update_env ORIGIN_HOOK "$SECURITY_HOOK"
update_env DESTINATION_EXECUTOR "$SECURITY_EXECUTOR"

if [[ -n "$INTENT_HOOK" && "$INTENT_HOOK" != "null" ]]; then
  update_env INTENT_HOOK "$INTENT_HOOK"
  update_env ORIGIN_INTENT_HOOK "$INTENT_HOOK"
fi
if [[ -n "$INTENT_EXECUTOR" && "$INTENT_EXECUTOR" != "null" ]]; then
  update_env INTENT_EXECUTOR "$INTENT_EXECUTOR"
  update_env DESTINATION_INTENT_EXECUTOR "$INTENT_EXECUTOR"
fi
if [[ -n "$INTENT_ADAPTER" && "$INTENT_ADAPTER" != "null" ]]; then
  update_env INTENT_ADAPTER "$INTENT_ADAPTER"
  update_env INTENT_SWAP_ADAPTER "$INTENT_ADAPTER"
fi
if [[ ${#origin_txs[@]} -gt 0 ]]; then
  update_env ORIGIN_DEPLOY_TX_HASHES "$(join_csv "${origin_txs[@]}")"
fi

phase "Deploy or reuse reactive contracts"
if [[ "$HAS_REACTIVE" == "1" && -n "$REACTIVE_RPC" && -n "$REACTIVE_PRIVATE_KEY" ]]; then
  export REACTIVE_RPC REACTIVE_PRIVATE_KEY REACTIVE_OWNER ORIGIN_CHAIN_ID DESTINATION_CHAIN_ID CALLBACK_GAS_LIMIT
  export SECURITY_HOOK SECURITY_EXECUTOR ORIGIN_HOOK="$SECURITY_HOOK" DESTINATION_EXECUTOR="$SECURITY_EXECUTOR"

  reactive_need_deploy=0
  if ! code_exists "$SECURITY_REACTIVE" "$REACTIVE_RPC"; then
    reactive_need_deploy=1
  fi
  if [[ "${FORCE_REACTIVE_DEPLOY:-0}" == "1" ]]; then
    reactive_need_deploy=1
  fi

  if [[ "$reactive_need_deploy" == "1" ]]; then
    reactive_out="$(cd "$ROOT_DIR/reactive" && ./scripts/deploy.sh 2>&1)"
    echo "$reactive_out"

    SECURITY_REACTIVE="$(echo "$reactive_out" | sed -nE 's/.*Deployed to:[[:space:]]*(0x[0-9a-fA-F]+).*/\1/p' | tail -n1)"
    REACTIVE_DEPLOY_TX_HASH="$(echo "$reactive_out" | sed -nE 's/.*Transaction hash:[[:space:]]*(0x[0-9a-fA-F]+).*/\1/p' | tail -n1)"

    if [[ -z "$SECURITY_REACTIVE" ]]; then
      echo "[demo] failed to parse reactive deployment address" >&2
      exit 1
    fi
    print_tx "Reactive Deployment" "$REACTIVE_DEPLOY_TX_HASH" "$REACTIVE_EXPLORER_BASE"
  else
    log "Reusing SecurityReactive: $SECURITY_REACTIVE"
    print_tx "Reactive Deployment (reused)" "$REACTIVE_DEPLOY_TX_HASH" "$REACTIVE_EXPLORER_BASE"
  fi

  update_env SECURITY_REACTIVE "$SECURITY_REACTIVE"
  update_env REACTIVE_SECURITY_CONTRACT "$SECURITY_REACTIVE"
  update_env REACTIVE_INTENT_CONTRACT "$SECURITY_REACTIVE"
  update_env REACTIVE_DEPLOY_TX_HASH "$REACTIVE_DEPLOY_TX_HASH"
else
  warn "Reactive deployment skipped (integration missing or REACTIVE_RPC/REACTIVE_PRIVATE_KEY not set)."
fi

phase "Auth wiring"
if [[ -n "$SECURITY_REACTIVE" && "$SECURITY_REACTIVE" != "null" ]]; then
  allowlisted_security="$(cast call "$SECURITY_EXECUTOR" "reactVMAllowlist(address)(bool)" "$SECURITY_REACTIVE" --rpc-url "$SEPOLIA_RPC" 2>/dev/null || echo "false")"
  if [[ "$allowlisted_security" != "true" ]]; then
    out="$(cast send "$SECURITY_EXECUTOR" "setReactVM(address,bool)" "$SECURITY_REACTIVE" true --rpc-url "$SEPOLIA_RPC" --private-key "$DEPLOYER_PRIVATE_KEY")"
    print_tx "Allowlist Security ReactVM" "$(extract_tx_hash "$out")" "$ORIGIN_EXPLORER_BASE"
  fi
fi

if [[ "$CALLBACK_PROXY" != "$DEPLOYER_ADDRESS" ]]; then
  out="$(cast send "$SECURITY_EXECUTOR" "setCallbackProxy(address)" "$DEPLOYER_ADDRESS" --rpc-url "$SEPOLIA_RPC" --private-key "$DEPLOYER_PRIVATE_KEY")"
  print_tx "Set Security Demo Callback Proxy" "$(extract_tx_hash "$out")" "$ORIGIN_EXPLORER_BASE"
fi

if [[ -n "$INTENT_EXECUTOR" && "$INTENT_EXECUTOR" != "null" ]]; then
  DEMO_REACT_VM_INTENT="${REACTIVE_INTENT_CONTRACT:-${SECURITY_REACTIVE:-$DEPLOYER_ADDRESS}}"
  allowlisted_intent="$(cast call "$INTENT_EXECUTOR" "reactVMAllowlist(address)(bool)" "$DEMO_REACT_VM_INTENT" --rpc-url "$SEPOLIA_RPC" 2>/dev/null || echo "false")"
  if [[ "$allowlisted_intent" != "true" ]]; then
    out="$(cast send "$INTENT_EXECUTOR" "setReactVM(address,bool)" "$DEMO_REACT_VM_INTENT" true --rpc-url "$SEPOLIA_RPC" --private-key "$DEPLOYER_PRIVATE_KEY")"
    print_tx "Allowlist Intent ReactVM" "$(extract_tx_hash "$out")" "$ORIGIN_EXPLORER_BASE"
  fi
  out="$(cast send "$INTENT_EXECUTOR" "setCallbackProxy(address)" "$DEPLOYER_ADDRESS" --rpc-url "$SEPOLIA_RPC" --private-key "$DEPLOYER_PRIVATE_KEY")"
  print_tx "Set Intent Demo Callback Proxy" "$(extract_tx_hash "$out")" "$ORIGIN_EXPLORER_BASE"
fi

phase "User perspective demo (intent lifecycle)"
user_flow_txs=()
if [[ "$RUN_INTENT_PROOF" == "1" && -n "$INTENT_EXECUTOR" && "$INTENT_EXECUTOR" != "null" && -n "$INTENT_HOOK" && "$INTENT_HOOK" != "null" ]]; then
  DEMO_REACT_VM_INTENT="${REACTIVE_INTENT_CONTRACT:-${SECURITY_REACTIVE:-$DEPLOYER_ADDRESS}}"
  intent_demo_out="$(
    cd "$ROOT_DIR/contracts"
    DESTINATION_EXECUTOR="$INTENT_EXECUTOR" ORIGIN_HOOK="$INTENT_HOOK" REACTIVE_INTENT_CONTRACT="$DEMO_REACT_VM_INTENT" \
      forge script script/DemoIntentProof.s.sol --rpc-url "$SEPOLIA_RPC" --private-key "$DEPLOYER_PRIVATE_KEY" --broadcast --slow -vv
  )"
  echo "$intent_demo_out"

  demo_token_a="$(echo "$intent_demo_out" | sed -nE 's/.*DemoTokenA:[[:space:]]*(0x[0-9a-fA-F]+).*/\1/p' | tail -n1)"
  demo_token_b="$(echo "$intent_demo_out" | sed -nE 's/.*DemoTokenB:[[:space:]]*(0x[0-9a-fA-F]+).*/\1/p' | tail -n1)"
  demo_intent_id="$(echo "$intent_demo_out" | sed -nE 's/.*IntentId:[[:space:]]*(0x[0-9a-fA-F]+).*/\1/p' | tail -n1)"

  if [[ -n "$demo_token_a" ]]; then update_env DEMO_TOKEN_A "$demo_token_a"; fi
  if [[ -n "$demo_token_b" ]]; then update_env DEMO_TOKEN_B "$demo_token_b"; fi
  if [[ -n "$demo_intent_id" ]]; then update_env DEMO_INTENT_ID "$demo_intent_id"; fi

  INTENT_BROADCAST="$ROOT_DIR/contracts/broadcast/DemoIntentProof.s.sol/$CHAIN_ID/run-latest.json"
  if [[ -f "$INTENT_BROADCAST" ]]; then
    while IFS= read -r tx; do
      [[ -z "$tx" ]] && continue
      user_flow_txs+=("$tx")
    done < <(jq -r '.receipts[]?.transactionHash // empty' "$INTENT_BROADCAST")

    idx=1
    for tx in "${user_flow_txs[@]}"; do
      print_tx "User Flow (Intent) #$idx" "$tx" "$ORIGIN_EXPLORER_BASE"
      idx=$((idx + 1))
    done
  fi
else
  warn "Intent proof skipped (missing intent contracts or RUN_INTENT_PROOF=0)."
fi

if [[ ${#user_flow_txs[@]} -gt 0 ]]; then
  update_env DEMO_USER_FLOW_TX_HASHES "$(join_csv "${user_flow_txs[@]}")"
fi

phase "Attack simulation (security lifecycle)"
DEMO_POOL_ID="${DEMO_POOL_ID:-0x1111111111111111111111111111111111111111111111111111111111111111}"
DEMO_REACT_VM_SECURITY="${SECURITY_REACTIVE:-$DEPLOYER_ADDRESS}"

extra_payload="$(cast abi-encode "f(uint24,uint16,uint128,uint64,uint16,uint8,bytes32)" 60000 1500 1000000000000000000 300 9000 4 0x435249544943414c5f5249534b00000000000000000000000000000000000000)"
attack_out="$(cast send "$SECURITY_EXECUTOR" "applyMitigation(address,bytes32,uint256,bytes)" "$DEMO_REACT_VM_SECURITY" "$DEMO_POOL_ID" 1 "$extra_payload" --rpc-url "$SEPOLIA_RPC" --private-key "$DEPLOYER_PRIVATE_KEY")"
attack_tx="$(extract_tx_hash "$attack_out")"
print_tx "Attack Simulation + Mitigation" "$attack_tx" "$ORIGIN_EXPLORER_BASE"

if [[ -n "$REACTIVE_DEPLOY_TX_HASH" ]]; then
  print_tx "Reactive Trace" "$REACTIVE_DEPLOY_TX_HASH" "$REACTIVE_EXPLORER_BASE"
fi

phase "Post-condition verification"
last_nonce="$(cast call "$SECURITY_EXECUTOR" "lastMitigationNonce(bytes32)(uint256)" "$DEMO_POOL_ID" --rpc-url "$SEPOLIA_RPC" 2>/dev/null || echo "0")"
log "SecurityExecutor.lastMitigationNonce(poolId): $last_nonce"

protection_state="$(cast call "$SECURITY_HOOK" "protectionStateByPoolId(bytes32)((uint24,uint16,uint128,uint64,uint16,uint64,uint256))" "$DEMO_POOL_ID" --rpc-url "$SEPOLIA_RPC" 2>/dev/null || echo "(unavailable)")"
log "SecurityHook.protectionStateByPoolId(poolId): $protection_state"

phase "Summary"
log "Security Hook: $SECURITY_HOOK"
log "Security Executor: $SECURITY_EXECUTOR"
if [[ -n "$INTENT_HOOK" && "$INTENT_HOOK" != "null" ]]; then
  log "Intent Hook: $INTENT_HOOK"
fi
if [[ -n "$INTENT_EXECUTOR" && "$INTENT_EXECUTOR" != "null" ]]; then
  log "Intent Executor: $INTENT_EXECUTOR"
fi
if [[ -n "$INTENT_ADAPTER" && "$INTENT_ADAPTER" != "null" ]]; then
  log "Intent Adapter: $INTENT_ADAPTER"
fi
if [[ -n "$SECURITY_REACTIVE" && "$SECURITY_REACTIVE" != "null" ]]; then
  log "Security Reactive: $SECURITY_REACTIVE"
fi
log "Updated env file: $ENV_FILE"
