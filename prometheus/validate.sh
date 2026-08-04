#!/usr/bin/env bash
# Validates every prometheus/targets/*.yml file has the required labels.
# Run in CI or as a pre-commit hook. Exits non-zero if any file is missing
# a required label, so bad target files never reach Prometheus silently.
#
# Usage:
#   ./validate.sh                  # validates ./*.yml in this directory
#   ./validate.sh /path/to/targets # validates files in a given directory

set -euo pipefail

TARGETS_DIR="${1:-$(dirname "$0")}"
REQUIRED_LABELS=("service" "team" "env")
FAILED=0

shopt -s nullglob
FILES=("$TARGETS_DIR"/*.yml)
shopt -u nullglob

if [ ${#FILES[@]} -eq 0 ]; then
  echo "No .yml files found in $TARGETS_DIR"
  exit 1
fi

for f in "${FILES[@]}"; do
  base="$(basename "$f")"

  # Skip the template itself
  if [[ "$base" == "_TEMPLATE.yml" ]]; then
    continue
  fi

  for label in "${REQUIRED_LABELS[@]}"; do
    if ! grep -qE "^\s*${label}:\s*\".+\"" "$f"; then
      echo "FAIL: $base is missing required label '${label}'"
      FAILED=1
    fi
  done

  # Warn (don't fail) on leftover placeholder values from the template
  if grep -qE "SERVICE_NAME|TEAM_NAME|PORT" "$f"; then
    echo "WARN: $base still contains an unfilled placeholder (SERVICE_NAME/TEAM_NAME/PORT)"
    FAILED=1
  fi

  # Sanity check: targets list isn't empty
  if ! grep -qE "^\s*-\s*targets:" "$f"; then
    echo "FAIL: $base has no 'targets:' key"
    FAILED=1
  fi
done

if [ "$FAILED" -eq 0 ]; then
  echo "All target files valid ($((${#FILES[@]})) checked)."
else
  echo ""
  echo "Validation failed. Fix the issues above before deploying."
fi

exit $FAILED