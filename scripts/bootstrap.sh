#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

PIN_V4_PERIPHERY="3779387e5d296f39df543d23524b050f89a62917"
PIN_V4_CORE="59d3ecf53afa9264a16bba0e38f4c5d2231f80bc"
FORGE_STD_URL="https://github.com/foundry-rs/forge-std"
HOOKMATE_URL="https://github.com/akshatmittal/hookmate"
UNISWAP_HOOKS_URL="https://github.com/openzeppelin/uniswap-hooks"

is_valid_repo() {
  local dir="$1"
  git -C "$dir" rev-parse --is-inside-work-tree >/dev/null 2>&1
}

rehydrate_repo() {
  local dir="$1"
  local url="$2"

  if is_valid_repo "$dir"; then
    return 0
  fi

  if [[ -d "$dir" ]]; then
    echo "[bootstrap] $dir exists but git metadata is invalid; keeping current directory as-is"
    echo "[bootstrap] cannot safely replace $dir without a known-good clone"
    return 0
  fi

  git clone --recurse-submodules "$url" "$dir"
}

if git submodule status lib/forge-std >/dev/null 2>&1; then
  echo "[bootstrap] syncing submodule metadata"
  git submodule sync --recursive

  echo "[bootstrap] initializing top-level submodules"
  git submodule update --init lib/forge-std lib/hookmate lib/uniswap-hooks
else
  echo "[bootstrap] top-level submodules not registered in git index, using clone fallback"
  rehydrate_repo "lib/forge-std" "$FORGE_STD_URL"
  rehydrate_repo "lib/hookmate" "$HOOKMATE_URL"
  rehydrate_repo "lib/uniswap-hooks" "$UNISWAP_HOOKS_URL"
fi

echo "[bootstrap] initializing Uniswap v4 dependencies"
git -C lib/uniswap-hooks submodule sync --recursive || true
git -C lib/uniswap-hooks submodule update --init lib/v4-core lib/v4-periphery

echo "[bootstrap] checking out pinned commits"
git -C lib/uniswap-hooks/lib/v4-periphery checkout "$PIN_V4_PERIPHERY"
git -C lib/uniswap-hooks/lib/v4-core checkout "$PIN_V4_CORE"
git -C lib/uniswap-hooks/lib/v4-periphery submodule update --init lib/v4-core
git -C lib/uniswap-hooks/lib/v4-periphery/lib/v4-core checkout "$PIN_V4_CORE"

echo "[bootstrap] verifying pin integrity"
./scripts/verify_uniswap_pin.sh

if command -v pnpm >/dev/null 2>&1; then
  echo "[bootstrap] installing pnpm workspace dependencies"
  pnpm install --ignore-workspace=false --frozen-lockfile
else
  echo "[bootstrap] pnpm not found; skipping frontend/shared dependency install"
fi

echo "[bootstrap] done"
