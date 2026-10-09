#!/usr/bin/env bash
# Convenience entry point for validating Prometheus file-based discovery targets.
# This script intentionally does not scan prometheus.yml or alert_rules.yml;
# those are configuration files, not target groups.
#
# Usage:
#   bash prometheus/validate.sh                 # validates all target groups
#   bash prometheus/validate.sh /path/to/targets # validates a target tree

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec bash "$SCRIPT_DIR/targets/validate.sh" "${1:-$SCRIPT_DIR/targets}"