#!/usr/bin/env python3
"""Render YAML config templates using safely quoted values from the environment."""
from __future__ import annotations

import json
import os
import re
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

PROMETHEUS_VARS = (
    "PROM_LARAVEL_BEARER_TOKEN",
    "PROM_NODEJS_BEARER_TOKEN",
    "PROM_NESTJS_BEARER_TOKEN",
)
ALERTMANAGER_VARS = (
    "ALERT_SMTP_SMARTHOST",
    "ALERT_SMTP_FROM",
    "ALERT_SMTP_USERNAME",
    "ALERT_SMTP_PASSWORD",
    "ALERT_EMAIL_TO",
    "ALERT_DISCORD_WEBHOOK_URL",
    "ALERT_SMS_WEBHOOK_URL",
)
PLACEHOLDER = re.compile(r"\$\{([A-Z][A-Z0-9_]*)\}")


def render(source: Path, destination: Path, names: tuple[str, ...]) -> None:
    text = source.read_text(encoding="utf-8")
    available = {name: os.environ.get(name, "") for name in names}
    missing = [name for name, value in available.items() if not value or "REPLACE_WITH" in value]
    if missing:
        raise SystemExit(f"Set these values in .env before rendering: {', '.join(missing)}")

    found: set[str] = set()

    def quote(match: re.Match[str]) -> str:
        name = match.group(1)
        if name not in available:
            raise SystemExit(f"Unsupported template variable {name} in {source.relative_to(ROOT)}")
        found.add(name)
        # JSON double-quoted strings are valid YAML scalars and correctly escape
        # punctuation, quotes, backslashes, and Unicode in supplied credentials.
        return json.dumps(available[name], ensure_ascii=False)

    rendered = PLACEHOLDER.sub(quote, text)
    if found != set(names):
        absent = sorted(set(names) - found)
        raise SystemExit(f"Expected placeholders missing from {source.relative_to(ROOT)}: {', '.join(absent)}")
    if PLACEHOLDER.search(rendered):
        raise SystemExit(f"Unexpanded template placeholder remains in {source.relative_to(ROOT)}")

    destination.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    destination.parent.chmod(0o700)
    fd, temporary_name = tempfile.mkstemp(prefix=f".{destination.name}.", dir=destination.parent)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as output:
            output.write(rendered)
        os.chmod(temporary_name, 0o444)
        os.replace(temporary_name, destination)
    finally:
        if os.path.exists(temporary_name):
            os.unlink(temporary_name)


def main() -> None:
    render(ROOT / "prometheus/prometheus.yml", ROOT / ".secrets/prometheus.yml", PROMETHEUS_VARS)
    render(ROOT / "alertmanager/alertmanager.yml", ROOT / ".secrets/alertmanager.yml", ALERTMANAGER_VARS)
    print("Rendered secret-bearing configs into ignored .secrets/. Do not print, publish, or commit these files.")


if __name__ == "__main__":
    main()
