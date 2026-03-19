#!/usr/bin/env bash
set -euo pipefail

LCOV_FILE="${1:-contracts/lcov.info}"
MIN_LINE="${MIN_LINE_COVERAGE:-100}"
MIN_BRANCH="${MIN_BRANCH_COVERAGE:-100}"
INCLUDE_REGEX="${COVERAGE_INCLUDE_REGEX:-^src/}"

if [[ ! -f "$LCOV_FILE" ]]; then
  echo "[coverage] missing lcov file: $LCOV_FILE"
  exit 1
fi

read -r lh lf brh brf scoped_files < <(
  awk -F: -v re="$INCLUDE_REGEX" '
    /^SF:/ {
      in_scope = ($2 ~ re)
      if (in_scope) {
        scoped_files += 1
      }
    }
    in_scope && /^LH:/ {lh += $2}
    in_scope && /^LF:/ {lf += $2}
    in_scope && /^BRH:/ {brh += $2}
    in_scope && /^BRF:/ {brf += $2}
    END {print lh, lf, brh, brf, scoped_files}
  ' "$LCOV_FILE"
)

if [[ "$scoped_files" -eq 0 ]]; then
  echo "[coverage] no files matched include regex: $INCLUDE_REGEX"
  exit 1
fi

if [[ "$lf" -eq 0 ]]; then
  echo "[coverage] no executable lines found for include regex: $INCLUDE_REGEX"
  exit 1
fi

line_cov=$(awk -v lh="$lh" -v lf="$lf" 'BEGIN { printf "%.2f", (lh/lf)*100 }')
branch_cov="100.00"
if [[ "$brf" -gt 0 ]]; then
  branch_cov=$(awk -v brh="$brh" -v brf="$brf" 'BEGIN { printf "%.2f", (brh/brf)*100 }')
fi

echo "[coverage] include regex: ${INCLUDE_REGEX} (matched files: ${scoped_files})"
echo "[coverage] line: ${line_cov}% (${lh}/${lf})"
echo "[coverage] branch: ${branch_cov}% (${brh}/${brf})"

line_fail=$(awk -v cov="$line_cov" -v min="$MIN_LINE" 'BEGIN { print (cov < min) ? 1 : 0 }')
branch_fail=$(awk -v cov="$branch_cov" -v min="$MIN_BRANCH" 'BEGIN { print (cov < min) ? 1 : 0 }')

if [[ "$line_fail" -eq 1 || "$branch_fail" -eq 1 ]]; then
  echo "[coverage] threshold failure. required line>=${MIN_LINE}, branch>=${MIN_BRANCH}"
  exit 1
fi

echo "[coverage] thresholds satisfied"
