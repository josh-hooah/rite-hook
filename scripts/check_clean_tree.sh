#!/usr/bin/env bash
set -euo pipefail

if [[ -n "$(git status --porcelain)" ]]; then
  echo "[tree-check] working tree is not clean"
  git status --short
  exit 1
fi

echo "[tree-check] working tree is clean"
