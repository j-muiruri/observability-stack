#!/usr/bin/env bash
# Validates every prometheus/targets/<stack>/*.yml file has the required
# labels. Run in CI or as a pre-commit hook.
#
# Usage:
#   ./validate.sh                    # validates everything under this dir
#   ./validate.sh /path/to/targets   # validates a specific targets root

set -euo pipefail

TARGETS_ROOT="${1:-$(dirname "$0")}"
REQUIRED_LABELS=("service" "team" "env" "stack")
FAILED=0
CHECKED=0

FILES=$(find "$TARGETS_ROOT" -name "*.yml" -not -name "_TEMPLATE.yml")

if [ -z "$FILES" ]; then
  echo "No target files found under $TARGETS_ROOT (besides templates)."
  exit 0
fi

while IFS= read -r f; do
  CHECKED=$((CHECKED + 1))
  base="$(basename "$f")"
  stack_dir="$(basename "$(dirname "$f")")"

  for label in "${REQUIRED_LABELS[@]}"; do
    if ! grep -qE "^\s*${label}:\s*\".+\"" "$f"; then
      echo "FAIL: $stack_dir/$base is missing required label '${label}'"
      FAILED=1
    fi
  done

  if grep -qE "SERVICE_NAME|TEAM_NAME|SERVICE_HOST|DB_HOST|REDIS_HOST|RABBITMQ_HOST|ACTIVEMQ_HOST|DOCKER_HOST|HOST_NAME|EXPORTER_HOST|CLOUDWATCH_EXPORTER_HOST" "$f"; then
    echo "WARN: $stack_dir/$base still contains an unfilled placeholder"
    FAILED=1
  fi

  if ! grep -qE "^\s*-\s*targets:" "$f"; then
    echo "FAIL: $stack_dir/$base has no 'targets:' key"
    FAILED=1
  fi
done <<< "$FILES"

echo ""
if [ "$FAILED" -eq 0 ]; then
  echo "All target files valid ($CHECKED checked across $(find "$TARGETS_ROOT" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ') stacks)."
else
  echo "Validation failed. Fix the issues above before deploying."
fi

exit $FAILED
