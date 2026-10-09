# Container release baseline

The Compose file uses explicit image tags so a pull/restart cannot silently change component versions. The first-party stack tags below were checked against their official release pages on **2026-10-09**. Exporter examples are also version-pinned; optional exporters are not Compose services.

| Component | Image tag | Upstream release source | Previous repository tag |
|---|---|---|---|
| Grafana OSS | `grafana/grafana:13.2.3` | [Grafana releases](https://github.com/grafana/grafana/releases) | `11.4.0` |
| Prometheus | `prom/prometheus:v3.15.0` | [Prometheus releases](https://github.com/prometheus/prometheus/releases) | `v2.55.1` |
| Alertmanager | `prom/alertmanager:v0.34.1` | [Alertmanager releases](https://github.com/prometheus/alertmanager/releases) | `v0.27.0` |
| Loki | `grafana/loki:3.7.8` | [Loki releases](https://github.com/grafana/loki/releases) | `3.2.1` |
| Tempo | `grafana/tempo:3.1.0` | [Tempo releases](https://github.com/grafana/tempo/releases) | `2.6.1` |
| Alloy | `grafana/alloy:v1.20.1` | [Alloy releases](https://github.com/grafana/alloy/releases) | `v1.5.1` |

## Optional exporter examples

| Exporter | Image tag | Upstream release source | Compatibility note |
|---|---|---|---|
| cAdvisor | `ghcr.io/google/cadvisor:v0.60.6` | [cAdvisor releases](https://github.com/google/cadvisor/releases) | The official registry changed to GHCR in v0.53.0. |
| node_exporter | `quay.io/prometheus/node-exporter:v1.12.1` | [node_exporter releases](https://github.com/prometheus/node_exporter/releases) | Host namespace and root filesystem mounts are required for host metrics. |
| redis_exporter | `oliver006/redis_exporter:v1.93.0` | [redis_exporter releases](https://github.com/oliver006/redis_exporter/releases) | |
| postgres_exporter | `ghcr.io/prometheus-community/postgres-exporter:v0.20.1` | [postgres_exporter releases](https://github.com/prometheus-community/postgres_exporter/releases) | v0.20 renamed replication-slot collector/metrics. |
| mysqld_exporter | `prom/mysqld-exporter:v0.20.0` | [mysqld_exporter releases](https://github.com/prometheus/mysqld_exporter/releases) | Credentials now use `.my.cnf`; `DATA_SOURCE_NAME` was removed in v0.15. |

## What was and was not verified

- The first-party versions shown here were the latest stable release tags confirmed on the date above, not prereleases or floating Docker `latest` tags. Prometheus v3.15.0 is newer than its separately maintained v3.13 LTS patch line; use the LTS branch instead if long-term maintenance is a requirement.
- The versions checked were Grafana OSS 13.2.3, Prometheus 3.15.0, Alertmanager 0.34.1, Loki 3.7.8, Tempo 3.1.0, and Alloy 1.20.1. The optional exporter tags above were verified on their official project release pages.
- Version lookup is not runtime verification. The working-tree configuration has not been started against these images here. Run product-matched validators and exercise a backup-restored copy before a real upgrade.
- Review upstream changes carefully, especially Prometheus 2-to-3 and Tempo 2-to-3/3.1. Tempo 3.x removed the old `ingester` and `compactor` config paths; the former five-minute ingester block interval maps to `live_store.max_block_duration`, and retention is now configured under `backend_scheduler.provider.compaction.compaction`. Tempo 3.1 writes new blocks using vParquet5 by default while remaining able to read existing vParquet4/vParquet3 blocks; no volume deletion or conversion is part of this update.
- Back up named volumes first. Tempo's newer versions write newer block formats; retain a recoverable copy of existing data and test read/query behavior before deleting or migrating any volume.

To review a future upgrade, compare the upstream release notes, edit the image tag in `docker-compose.yml`, run syntax/config validators against the new image, then start a copy of the stack with a restored backup and exercise ingestion, queries, dashboards, alerts, and rollback. Keep a backup until rollback has been tested; do not use `docker compose down -v` as an upgrade step.
