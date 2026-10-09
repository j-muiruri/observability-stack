# Self-hosted Observability Stack

A single-host Grafana LGTM + Alloy stack for **Grafana, Prometheus, Loki, Tempo, Alertmanager, and Grafana Alloy**, with examples for application metrics, logs, and traces. It is suitable for a controlled self-hosted deployment, but it is not a highly available or horizontally scalable observability platform. Plan on about 45-90 minutes to bring up and validate the stack, then additional time for each application you instrument.

> **Know the deployment boundary:** Compose publishes service ports on the host interfaces. The included configuration does not provide an ingress proxy, TLS, SSO, network policy, or high availability. Restrict access with host/network firewalls and add your organization's authenticated TLS ingress before making any UI or ingest endpoint reachable outside a trusted network. This single-host design uses local named volumes; it is not a substitute for a distributed backend or tested backup/restore plan.

## Start here

### Requirements

- Docker Engine/Desktop with Docker Compose v2 (`docker compose`)
- At least 4 GB of free RAM for a local validation run or 8 GB of free RAM for production, then Docker host sizing based on measured ingestion/query load; the Compose resource ceilings are conservative and may throttle busy workloads
- Ports `3001`, `3100`, `3200`, `4317`, `4318`, `4319`, `4320`, `9090`, `9093`, and `12345` available on the Docker host

### 1. Set credentials and review scrape targets

Copy `.env.example` to `.env`, replace every `REPLACE_WITH` value with credentials/endpoints for your environment, and restrict the file to its owner (`chmod 600 .env`). Use unique high-entropy secrets; keep `.env` out of Git. The Prometheus bearer token values previously embedded in the tracked config must be revoked/rotated before use. Rotating them does not erase old commits, clones, or backups.

Render the active Prometheus and Alertmanager configs from `.env` before starting the stack:

```bash
bash scripts/render-configs.sh
```

The resulting secret-bearing files are in `.secrets/`, which is ignored by Git and owner-only on the host. Do not print, share, or commit them. Re-render after changing `.env` or either source config. For a multi-node production deployment, do not distribute this local dotenv workflow; use a secret manager or platform-mounted secret files (see [production and HA guidance](docs/PRODUCTION-HA.md)).

Inspect `prometheus/prometheus.yml` and every referenced file under `prometheus/targets/` before starting. These targets may refer to production services. Confirm every endpoint is intentional and reachable from the Prometheus container; never point an internet-accessible stack at sensitive endpoints without authenticated, encrypted transport.

### 2. Validate and start

```bash
docker compose config --quiet
docker compose pull
docker compose up -d
docker compose ps
```

To check startup logs:

```bash
docker compose logs --tail=100 grafana prometheus loki tempo alloy alertmanager
```

`docker compose ps` reports container state, not application readiness. Check service health endpoints in **Troubleshooting** below.

Quick smoke checks (an HTTP `200` from each endpoint means the service is ready):

```bash
curl -fsS http://localhost:3001/api/health
curl -fsS http://localhost:9090/-/ready
curl -fsS http://localhost:9093/-/ready
curl -fsS http://localhost:3100/ready
curl -fsS http://localhost:3200/ready
curl -fsS http://localhost:12345/-/ready
```

### 3. Open the local tools

| Service | URL | Purpose |
|---|---|---|
| Grafana | <http://localhost:3001> | Dashboards and Explore; sign in with `GF_SECURITY_ADMIN_USER` and `GF_SECURITY_ADMIN_PASSWORD` from `.env` |
| Prometheus | <http://localhost:9090> | Targets, rules, PromQL and scrape diagnostics |
| Alertmanager | <http://localhost:9093> | Alert grouping and routing status |
| Loki | <http://localhost:3100/ready> | Log backend readiness (API on port 3100) |
| Tempo | <http://localhost:3200/ready> | Trace backend readiness (query API on port 3200) |
| Alloy | <http://localhost:12345> | Telemetry pipeline status and diagnostics |

Grafana provisions Prometheus, Loki, Tempo, and Alertmanager datasources, plus the JSON dashboards in `grafana/provisioning/dashboards/json/`. Dashboards in `examples/dashboards/` are examples and are not automatically provisioned.

### 4. Verify each layer in order

Do not skip ahead if one layer fails; each later check depends on the earlier path working.

1. **Prometheus:** open <http://localhost:9090/targets>. The stack's own targets should be `UP`. Application targets that are not running yet will be `DOWN`; that is expected until you instrument and start those apps.
2. **Alloy:** open <http://localhost:12345>. The OTLP receiver, Tempo exporter, Loki exporter/write path, and Docker log discovery components should be healthy.
3. **Grafana:** open <http://localhost:3001>, sign in with the `.env` admin credentials, and use **Connections -> Data sources** to test Prometheus, Loki, Tempo, and Alertmanager. In **Dashboards -> Observability**, the provisioned dashboards should load even if application panels show `No data` before instrumentation.
4. **Alertmanager:** open <http://localhost:9093> and confirm alerts are visible after Prometheus evaluates rules. Use <http://localhost:9090/rules> to inspect rule health before troubleshooting notification delivery.

If these checks pass, the stack is wired; the remaining work is pointing real applications at it.

## Send telemetry from an application

### Traces and logs over OTLP

Alloy is the single host-side OTLP entry point. For an app running directly on the host, configure the OpenTelemetry SDK with the HTTP endpoint:

```text
OTEL_SERVICE_NAME=my-service
OTEL_EXPORTER_OTLP_PROTOCOL=http/protobuf
OTEL_EXPORTER_OTLP_ENDPOINT=http://localhost:4320
```

For OTLP/gRPC, use the Alloy host port `4319` with the SDK's gRPC protocol setting. When an application runs in another container on the Compose network, use `alloy:4318` (HTTP) or `alloy:4317` (gRPC), not `localhost`.

Alloy forwards traces to Tempo and OTLP logs to Loki. Alloy also discovers and tails Docker container logs through `/var/run/docker.sock`. Docker socket access grants powerful control of the Docker host: retain this feature only on trusted hosts, or remove the socket mount and corresponding Docker discovery/source components if your security policy prohibits it.

### Prometheus metrics

Prometheus scrapes application endpoints directly. Put a target file in the directory referenced by the matching job in `prometheus/prometheus.yml` and use a reachable target address:

- Host application: `host.docker.internal:<port>` (supported by the Compose `extra_hosts` mapping)
- Container on this Compose network: `<service-name>:<port>`

The scrape job determines the metrics path for several categories (for example, Laravel and Node.js use `/metrics`; Spring Boot uses `/actuator/prometheus`). Inspect the corresponding job in `prometheus/prometheus.yml` before adding a target. File discovery refreshes every 30 seconds.

Each target should include bounded, useful labels such as `service`, `team`, `env`, and `stack`. Never use user IDs, request IDs, raw URLs, or other per-request values as metric labels. Run the target checks after editing:

```bash
bash prometheus/targets/validate.sh
```

The runnable examples and setup instructions are in [examples/nodejs/README.md](examples/nodejs/README.md), [examples/java/README.md](examples/java/README.md), and [examples/php-laravel/README.md](examples/php-laravel/README.md). The reference for exporters and target-file patterns is in [exporters-reference/README.md](exporters-reference/README.md).

Pick one business-critical service per language first instead of trying to instrument every service at once. Follow the language guides in this order if you have all three stacks:

1. [PHP/Laravel](examples/php-laravel/README.md)
2. [Node.js](examples/nodejs/README.md)
3. [Java/Spring Boot](examples/java/README.md)

As each service comes online, re-check <http://localhost:9090/targets>. The corresponding job should move from `DOWN` to `UP`. For host processes, keep using `host.docker.internal:<port>`. For app containers defined in this Compose project, use the service DNS name and port, for example `<service-name>:<port>`. For a separately started container, attach it to the stack network first:

```bash
docker network connect observability <container>
```

Then point the matching Prometheus target file at `<container-name>:<port>`.

## Confirm the data path

1. Check <http://localhost:9090/targets>. Targets for applications that are not running will be `DOWN`; self-scrapes should be `UP`.
2. Generate a few application requests, for example `curl http://localhost:<app-port>/`, and check that the service's request metrics are present in Prometheus.
3. In Grafana Explore, query Prometheus for the service's metrics.
4. Switch Explore to Tempo and search for recent traces from the same service. Open a trace and note its `trace_id`.
5. Switch Explore to Loki and query the service's logs, for example `{service="my-service"}`. For trace/log correlation, ensure logs contain a `trace_id` field. The provisioned Loki datasource includes a derived-field link for JSON logs containing `"trace_id":"..."`.
6. Check the provisioned Grafana dashboards in the **Observability** folder. Request rate, error rate, and latency panels should populate once the app is serving instrumented traffic.

If the correlation check works for one service in one language, the telemetry pattern is proven. Repeat the same process for the next service.

## Turn on real alerting

Alertmanager routes critical, warning, and informational alerts to the email/webhook receivers configured by `.env` and rendered from `alertmanager/alertmanager.yml`. Replace all sample values and test delivery before relying on notifications. Prometheus scrape bearer credentials are likewise supplied from `.env` and rendered from `prometheus/prometheus.yml`. Prometheus alerts are defined in `prometheus/alert_rules.yml`; verify their state at <http://localhost:9090/rules>.

After editing `.env`, re-render the secret-bearing configs and restart the affected services:

```bash
bash scripts/render-configs.sh
docker compose restart alertmanager prometheus
```

For rule-only changes, Prometheus can reload without a restart:

```bash
curl -X POST http://localhost:9090/-/reload
```

Then force one safe, real alert to prove the full path. For example, stop one instrumented non-production app and confirm `ServiceDown` fires within about 1 minute, appears in Alertmanager, and reaches the configured receiver. Restart the app and confirm the alert resolves. Use a throwaway webhook endpoint for the first delivery test if your production on-call channel should not receive test alerts.

## Optional dashboards

The checked-in dashboards cover the local stack, infrastructure, and Java/Spring Boot examples. Once the core path is working, you can import fuller community dashboards from grafana.com into the **Observability** folder:

| Dashboard | ID | Use when |
|---|---:|---|
| Node Exporter Full | 1860 | You add `node_exporter` for host metrics |
| JVM / Micrometer | 4701 | Your Java app exposes Spring Boot Actuator metrics |
| Loki logs overview | 13639 | You want a general log-volume view by service |

## Tune it for your workload

The Compose file contains fixed CPU/memory ceilings that may constrain throughput; adjust them to match measured host capacity and workload. For practical performance work, measure scrape/ingest rate, active series and label cardinality, query latency, process memory/CPU, disk throughput, and retained bytes before changing limits or intervals. See [docs/PERFORMANCE.md](docs/PERFORMANCE.md) for a measurement-first tuning guide.

Prometheus retains data for 7 days. Loki is configured for 14 days and Tempo for 7 days. All three use named Docker volumes; ensure the Docker host storage is durable, monitored, and backed up according to your retention requirements.

## Upgrade and maintain

Container versions are explicitly pinned. Review [docs/RELEASES.md](docs/RELEASES.md) before upgrading: latest tags may contain breaking configuration or storage changes. Back up the named volumes before upgrades, validate configurations with the matching product binaries, and test restore/rollback before changing a production system. Never use `docker compose down -v` unless you intend to delete all stored telemetry and Grafana state.

For stack ownership and future changes, use the workspace agent **Observability Stack Maintainer** from `.github/agents/observability-stack-maintainer.agent.md`.

## Troubleshooting

| Symptom | Checks |
|---|---|
| Compose rejects configuration | Run `docker compose config` and fix any reported interpolation/YAML error. |
| Grafana cannot connect to a datasource | In Grafana, use the Compose service URL (`http://prometheus:9090`, `http://loki:3100`, or `http://tempo:3200`), not `localhost`. Inspect `docker compose logs grafana <backend>`. |
| Prometheus target is `DOWN` | Confirm the app is listening, target host/port/path are right, and the target is reachable from a container. On Linux, `host.docker.internal` is added by Compose; confirm the target is not using a host-only bind address inaccessible from containers. |
| No traces or OTLP logs | Check the SDK protocol and endpoint, then inspect Alloy's component health and logs. Host apps use port `4320` for HTTP or `4319` for gRPC. |
| Alert is visible but no message arrives | Replace the sample SMTP/webhook/SMS values, validate the Alertmanager config, and check `docker compose logs alertmanager`. |
| Need to remove stored data | `docker compose down -v` removes persisted telemetry and Grafana data. Use it only when deletion is intended; it is not an upgrade or troubleshooting step. |

## Production boundary

This Compose file is a single-host stack and is not an HA or horizontally scalable production topology. Read [docs/PRODUCTION-HA.md](docs/PRODUCTION-HA.md) before production use for component-by-component HA patterns, storage, scaling boundaries, security requirements, and current upstream references. In production, provide authenticated TLS ingress/OTLP endpoints, secret-manager integration, multi-failure-domain scheduling, durable shared object storage where supported, backup/restore and upgrade procedures, and measured capacity planning. Prometheus's remote-write receiver is enabled for Tempo's generated span/service-graph metrics in this sample; it is not a substitute for a secured, scalable metrics backend.

Before promoting this beyond a trusted local or single-host environment:

- Put Grafana and any ingest endpoints behind authenticated TLS ingress; do not rely on default Compose port publishing as a security boundary.
- Move Alertmanager delivery from test endpoints to your real email, incident, webhook, or paging channel and prove both firing and resolved notifications.
- Set retention deliberately. This repository currently uses 7 days for Prometheus, 14 days for Loki, and 7 days for Tempo; increase only after sizing disk and backup requirements.
- Add host and data-layer exporters such as `node_exporter`, database exporters, Redis exporters, or messaging exporters where your environment needs them.
- Restrict or remove Alloy's Docker socket mount if container log discovery is not worth the host-level access it grants.
- Replace `host.docker.internal` development targets with real service DNS names or IP addresses.
- Re-run the metrics, logs, traces, dashboard, and alerting checks against the production endpoints before calling the deployment ready.
