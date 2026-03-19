#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
if [[ -f "$ROOT_DIR/.env" ]]; then
  # shellcheck disable=SC1090
  set -a && source "$ROOT_DIR/.env" && set +a
fi

REACTIVE_RPC="${REACTIVE_RPC:-${REACTIVE_RPC_URL:-}}"
REACTIVE_PRIVATE_KEY="${REACTIVE_PRIVATE_KEY:-${SEPOLIA_PRIVATE_KEY:-}}"
REACTIVE_OWNER="${REACTIVE_OWNER:-${OWNER_ADDRESS:-}}"
SECURITY_HOOK="${SECURITY_HOOK:-${ORIGIN_HOOK:-}}"
SECURITY_EXECUTOR="${SECURITY_EXECUTOR:-${DESTINATION_EXECUTOR:-}}"

: "${REACTIVE_RPC:?REACTIVE_RPC/REACTIVE_RPC_URL is required}"
: "${REACTIVE_PRIVATE_KEY:?REACTIVE_PRIVATE_KEY is required}"
: "${ORIGIN_CHAIN_ID:?ORIGIN_CHAIN_ID is required}"
: "${DESTINATION_CHAIN_ID:?DESTINATION_CHAIN_ID is required}"
: "${SECURITY_HOOK:?SECURITY_HOOK/ORIGIN_HOOK is required}"
: "${SECURITY_EXECUTOR:?SECURITY_EXECUTOR/DESTINATION_EXECUTOR is required}"
: "${REACTIVE_OWNER:?REACTIVE_OWNER/OWNER_ADDRESS is required}"

CALLBACK_GAS_LIMIT="${CALLBACK_GAS_LIMIT:-1500000}"

cd "$ROOT_DIR/reactive"

forge create \
  --broadcast \
  --rpc-url "$REACTIVE_RPC" \
  --private-key "$REACTIVE_PRIVATE_KEY" \
  src/SecurityReactive.sol:SecurityReactive \
  --constructor-args \
    "$REACTIVE_OWNER" \
    "$ORIGIN_CHAIN_ID" \
    "$DESTINATION_CHAIN_ID" \
    "$SECURITY_HOOK" \
    "$SECURITY_EXECUTOR" \
    "$CALLBACK_GAS_LIMIT"
