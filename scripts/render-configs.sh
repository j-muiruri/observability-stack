#!/usr/bin/env bash
# Render Prometheus and Alertmanager configs with secrets from the ignored .env.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

if [[ ! -f .env ]]; then
  echo "Missing .env. Copy .env.example to .env and replace every REPLACE_WITH value." >&2
  exit 1
fi
if ! command -v python3 >/dev/null 2>&1; then
  echo "python3 is required to render secret-bearing YAML safely." >&2
  exit 1
fi

# .env must use shell-compatible assignments. Do not print or log its contents.
set -a
# shellcheck disable=SC1091
. ./.env
set +a

required_vars=(
  GF_SECURITY_ADMIN_PASSWORD GF_SMTP_HOST GF_SMTP_USER GF_SMTP_PASSWORD
  GF_SMTP_FROM_ADDRESS PROM_LARAVEL_BEARER_TOKEN PROM_NODEJS_BEARER_TOKEN
  PROM_NESTJS_BEARER_TOKEN ALERT_SMTP_SMARTHOST ALERT_SMTP_FROM
  ALERT_SMTP_USERNAME ALERT_SMTP_PASSWORD ALERT_EMAIL_TO
  ALERT_DISCORD_WEBHOOK_URL ALERT_SMS_WEBHOOK_URL
)
for name in "${required_vars[@]}"; do
  if [[ -z "${!name:-}" || "${!name}" == *REPLACE_WITH* ]]; then
    echo "Set $name in .env before rendering configuration." >&2
    exit 1
  fi
done

exec python3 scripts/render-configs.py
