#!/usr/bin/env bash
set -euo pipefail

PIN_V4_PERIPHERY="3779387e5d296f39df543d23524b050f89a62917"
PIN_V4_CORE="59d3ecf53afa9264a16bba0e38f4c5d2231f80bc"

V4_PERIPHERY_DIR="lib/uniswap-hooks/lib/v4-periphery"
V4_CORE_DIR="lib/uniswap-hooks/lib/v4-core"
NESTED_CORE_DIR="lib/uniswap-hooks/lib/v4-periphery/lib/v4-core"

resolve_head() {
  local dir="$1"
  local name="$2"
  local head
  local prefix

  if [[ ! -d "$dir" ]]; then
    echo "[pin-check] missing directory: $dir" >&2
    return 1
  fi

  if ! prefix=$(git -C "$dir" rev-parse --show-prefix 2>/dev/null); then
    echo "[pin-check] unable to inspect git metadata for $name at $dir" >&2
    echo "[pin-check] run ./scripts/bootstrap.sh to repair/initialize dependencies" >&2
    return 1
  fi

  if [[ -n "$prefix" ]]; then
    echo "[pin-check] $name at $dir is not a standalone git checkout" >&2
    echo "[pin-check] run ./scripts/bootstrap.sh to repair/initialize dependencies" >&2
    return 1
  fi

  if ! head=$(git -C "$dir" rev-parse HEAD 2>/dev/null); then
    echo "[pin-check] unable to read git HEAD for $name at $dir" >&2
    echo "[pin-check] run ./scripts/bootstrap.sh to repair/initialize dependencies" >&2
    return 1
  fi

  echo "$head"
}

if ! actual_periphery=$(resolve_head "$V4_PERIPHERY_DIR" "v4-periphery"); then
  exit 1
fi
if ! actual_core=$(resolve_head "$V4_CORE_DIR" "v4-core"); then
  exit 1
fi
if ! actual_nested_core=$(resolve_head "$NESTED_CORE_DIR" "nested v4-core"); then
  exit 1
fi

if [[ "$actual_periphery" != "$PIN_V4_PERIPHERY" ]]; then
  echo "[pin-check] v4-periphery mismatch"
  echo "  expected: $PIN_V4_PERIPHERY"
  echo "  actual:   $actual_periphery"
  exit 1
fi

if [[ "$actual_core" != "$PIN_V4_CORE" ]]; then
  echo "[pin-check] v4-core mismatch"
  echo "  expected: $PIN_V4_CORE"
  echo "  actual:   $actual_core"
  exit 1
fi

if [[ "$actual_nested_core" != "$PIN_V4_CORE" ]]; then
  echo "[pin-check] nested v4-core mismatch"
  echo "  expected: $PIN_V4_CORE"
  echo "  actual:   $actual_nested_core"
  exit 1
fi

echo "[pin-check] Uniswap v4 dependencies are pinned correctly."
