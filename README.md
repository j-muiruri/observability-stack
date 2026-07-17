# Local Observability Stack — Step-by-Step

This brings up the full Grafana LGTM + Alloy stack from the report, locally, on Docker, so you can
validate it before touching production. Estimated time: 45–90 minutes for the stack itself, then as
long as you want per app you instrument.

Prerequisites: Docker + Docker Compose installed, ~4GB RAM free, ports 3000/9090/9093/3100/3200/4319/4320/12345 free.

---

## Step 1 — Bring up the stack

```bash
cd observability-stack
docker compose up -d
docker compose ps
```

All six containers (`grafana`, `prometheus`, `alertmanager`, `loki`, `tempo`, `alloy`) should show
`Up`/`healthy`. If any restart-loops, check its logs before moving on:

```bash
docker compose logs -f <service-name>
```

## Step 2 — Verify each layer independently, in this order

Don't skip ahead if a step fails — each layer depends on the previous one working.

**2a. Prometheus itself**
Open http://localhost:9090/targets — you should see `prometheus` and `alloy` targets as `UP`.
The `php-laravel-app`, `node-app`, `java-app` targets will show `DOWN` — that's expected, you
haven't started those apps yet.

**2b. Alloy**
Open http://localhost:12345 — the component graph should show green/healthy nodes for
`otelcol.receiver.otlp`, `otelcol.exporter.otlp`, `otelcol.exporter.loki`, `loki.write`.

**2c. Grafana**
Open http://localhost:3000 (login `admin` / `admin`, you'll be prompted to change it).
Go to Connections → Data sources — Prometheus, Loki and Tempo should all show a green
"Data source is working" when you click each and hit "Save & test".
Go to Dashboards → Observability folder — you should see "Tier 1 - Service Overview" already
provisioned (it'll show "No data" until Step 3).

**2d. Alertmanager**
Open http://localhost:9093 — within about a minute you should see the `WiringTest` alert
(from `prometheus/alert_rules.yml`) appear here. This confirms Prometheus → Alertmanager wiring
works before you touch a real alert. Delete that rule once confirmed (see Step 5).

If all four check out, the stack itself is solid — everything else is about pointing your apps at it.

## Step 3 — Instrument one real service per language

Pick your **most business-critical** service in each language first (per the report's Day 1–3 scoping —
don't try to instrument everything at once). Follow, in order:

1. `examples/php-laravel/README.md`
2. `examples/nodejs/README.md`
3. `examples/java/README.md`

Each one tells you exactly what to install, what files to copy in, and how to self-check before moving
on. As you finish each, re-check http://localhost:9090/targets — the corresponding job should flip to
`UP`.

**If your apps run directly on your host machine** (not in Docker), the configs are already set up for
that — `host.docker.internal` is how the containers reach them. **If you containerize an app instead**,
join it to the `observability` external network (`docker network connect observability <container>`) and
update its job's target in `prometheus/prometheus.yml` to `<container_name>:<port>`.

## Step 4 — Confirm end-to-end correlation

This is the part that's easy to get wrong and worth testing deliberately, not just assuming it works:

1. Hit an instrumented endpoint a few times: `curl http://localhost:8000/` (or 3001, or 8080).
2. In Grafana, go to Explore → Tempo → "Search" — you should see recent traces for your service.
3. Click into one — note its `trace_id`.
4. Switch Explore to Loki, query `{service="laravel-app"}` (or your service label) — find a log line
   from around the same time. If your log formatter includes `trace_id` (Sections 2–3 of each
   example's README), you should be able to click straight from that log line to the trace
   (this is what `derivedFields` in `datasources.yml` wires up).
5. Back in the Tier 1 dashboard, confirm the request rate / error rate / latency panels for that
   service are now populated instead of "No data".

If step 4 works for one service in one language, the pattern is proven — repeat Step 3 for the rest.

## Step 5 — Turn on real alerting

1. Open `alertmanager/alertmanager.yml`, uncomment **one** of the receiver options (Slack is the
   easiest to test — use a throwaway https://webhook.site URL first if you don't want to wire Slack
   yet), then:
   ```bash
   docker compose restart alertmanager
   ```
2. Remove the `test-alert` group from `prometheus/alert_rules.yml` (it's only there to prove the
   pipeline works) and reload Prometheus without a restart:
   ```bash
   curl -X POST http://localhost:9090/-/reload
   ```
3. Force a real alert to fire to prove it end-to-end: stop one instrumented app
   (`ServiceDown` should fire within ~1 minute) and confirm the notification arrives wherever you
   configured. Restart the app and confirm the alert resolves.

## Step 6 — Import fuller community dashboards (optional but recommended)

The Tier 1 dashboard here is intentionally minimal. Once you're comfortable, import these from
grafana.com/grafana/dashboards into the same "Observability" folder (Dashboards → New → Import, paste
the dashboard ID, pick the matching Prometheus datasource):

| Dashboard | ID | For |
|---|---|---|
| Node Exporter Full | 1860 | Host metrics (add `node_exporter` first — not included in this minimal stack) |
| JVM (Micrometer) | 4701 | Your Java app once `/actuator/prometheus` is scraped |
| Loki logs overview | 13639 | Log volume by service |

## Step 7 — Before you promote this to production

Checklist, matching Section 3.3 and Section 9 of the report:

- [ ] Put Grafana behind TLS + real auth (not `admin`/`admin`) — reverse proxy with Let's Encrypt, or
      your existing ingress/load balancer.
- [ ] Move Alertmanager's receiver from a test webhook to your real Slack/PagerDuty/email channel.
- [ ] Set retention deliberately: this local config uses 15d (Prometheus), 14d (Loki), 7d (Tempo) — the
      report's Section 3.3 defaults. Increase only if you have the disk for it.
- [ ] Add `node_exporter`, `mysqld_exporter`/`postgres_exporter`, `redis_exporter` for the data layer —
      not included in this local stack since it's dev-focused, but every job for them just needs adding
      to `prometheus/prometheus.yml` following the same pattern.
- [ ] Restrict the Docker socket mount on Alloy (`/var/run/docker.sock`) or drop it entirely in
      production if you don't need container log discovery there.
- [ ] Move from Prometheus's local disk to remote-write into Mimir, or increase disk, once retention
      needs outgrow a single node (Section 9.2 of the report).
- [ ] Re-point every `host.docker.internal` reference at real service DNS names / IPs once apps are on
      real hosts.
- [ ] Re-run Step 4's correlation check against the production endpoints before calling it done.

---

## Troubleshooting

| Symptom | Likely cause |
|---|---|
| Prometheus target shows `DOWN` | App isn't running, wrong port in `prometheus.yml`, or `host.docker.internal` isn't resolving (Linux: needs Docker 20.10+; confirm `extra_hosts` took effect with `docker exec prometheus getent hosts host.docker.internal`) |
| No traces in Tempo | Check your app's `OTEL_EXPORTER_OTLP_ENDPOINT` points at `:4320` (HTTP) not `:4319` (gRPC) unless your SDK is configured for gRPC; check Alloy's UI (Step 2b) for receiver errors |
| No logs in Loki | Confirm your app is actually emitting JSON logs with a `service` field — Loki only indexes labels, so an unlabeled log stream won't show up under `{service="..."}` queries |
| Alertmanager never fires | Confirm `rule_files` path in `prometheus.yml` matches the mounted path, and check http://localhost:9090/rules for syntax errors in `alert_rules.yml` |
