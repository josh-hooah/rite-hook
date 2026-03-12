#!/usr/bin/env bash
set -euo pipefail

EXPECTED_COUNT=300
EXPECTED_AUTHOR_NAME="josh-hooah"
EXPECTED_AUTHOR_EMAIL="jesuorobonosakhare873@gmail.com"

count=$(git rev-list --count HEAD)
if [[ "$count" -ne "$EXPECTED_COUNT" ]]; then
  echo "[commit-check] expected $EXPECTED_COUNT commits, found $count"
  exit 1
fi

invalid_names=$(git log --format='%an' | awk -v expected="$EXPECTED_AUTHOR_NAME" '$0 != expected {print $0}' | head -n 1 || true)
if [[ -n "$invalid_names" ]]; then
  echo "[commit-check] found unexpected author name: $invalid_names"
  exit 1
fi

invalid_emails=$(git log --format='%ae' | awk -v expected="$EXPECTED_AUTHOR_EMAIL" '$0 != expected {print $0}' | head -n 1 || true)
if [[ -n "$invalid_emails" ]]; then
  echo "[commit-check] found unexpected author email: $invalid_emails"
  exit 1
fi

echo "[commit-check] commit count and author metadata validated"
