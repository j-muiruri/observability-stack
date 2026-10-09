# Exporter Reference — Setup Per Stack

Each section: what to install, minimum config, default port, and the metric
names your Prometheus queries/dashboards will use. Ports below match what's
already wired into `prometheus/targets/*/​_TEMPLATE.yml` — change both together
if you deviate.

---

## Java / Spring Boot

**Add dependencies** (`pom.xml`):
```xml
<dependency>
  <groupId>org.springframework.boot</groupId>
  <artifactId>spring-boot-starter-actuator</artifactId>
</dependency>
<dependency>
  <groupId>io.micrometer</groupId>
  <artifactId>micrometer-registry-prometheus</artifactId>
</dependency>
```

**`application.yml`:**
```yaml
management:
  endpoints:
    web:
      exposure:
        include: health,info,prometheus,metrics
  endpoint:
    prometheus:
      enabled: true
  metrics:
    tags:
      application: ${spring.application.name}
      environment: ${ENVIRONMENT:production}
```

Metrics land on `GET /actuator/prometheus`, port defaults to your app's HTTP
port (8080 typically) — not a separate exporter process. This is why the
`spring-boot` job in `prometheus.yml` sets `metrics_path: /actuator/prometheus`
directly against the app port.

Key metric families: `http_server_requests_seconds_*` (RED), `jvm_memory_*`,
`jvm_gc_*`, `process_cpu_usage`, `hikaricp_connections_*` (if using HikariCP —
gives you DB pool saturation for free).

**Import dashboard 12900 or 4701** from grafana.com as a starting point, or use
the custom Java/Spring Boot dashboard included in this deliverable.

---

## Plain Java (non-Spring)

No Actuator equivalent, so use **jmx_exporter** as a Java agent:

```bash
-javaagent:/opt/jmx_exporter/jmx_prometheus_javaagent.jar=9404:/opt/jmx_exporter/config.yml
```

`config.yml` (minimal, exposes all JMX MBeans):
```yaml
startDelaySeconds: 0
lowercaseOutputName: true
lowercaseOutputLabelNames: true
```

Metrics land on `:9404/metrics`. This is intrusive to the JVM startup command —
coordinate with whoever manages the deploy/systemd unit/Dockerfile ENTRYPOINT.

---

## PHP (plain, non-Laravel)

Use **promphp/prometheus_client_php**:
```bash
composer require promphp/prometheus_client_php
```

Minimal `/metrics` endpoint (needs a storage adapter — APCu is simplest for
single-host, Redis for multi-instance so counters aggregate correctly):
```php
$adapter = new Prometheus\Storage\APCu();
$registry = new Prometheus\CollectorRegistry($adapter);
$renderer = new Prometheus\RenderTextFormat();
header('Content-Type: ' . Prometheus\RenderTextFormat::MIME_TYPE);
echo $renderer->render($registry->getMetricFamilySamples());
```

**Important:** PHP-FPM's request model means each request is a fresh process —
an in-process registry loses state between requests unless backed by APCu or
Redis. Don't use the default in-memory adapter in production.

## PHP-FPM (pool-level metrics — separate from app metrics)

Enable FPM's status page in the pool config:
```ini
pm.status_path = /status
```

Run **hipages/php-fpm_exporter** as a sidecar pointed at that status page:
```bash
docker run -e PHP_FPM_SCRAPE_URI="tcp://127.0.0.1:9000/status" \
  -p 9253:9253 hipages/php-fpm_exporter
```

Gives you `phpfpm_active_processes`, `phpfpm_queue_len` (requests waiting for
a free worker — this is your PHP-FPM saturation signal, analogous to the
worker-pool panel in the BullMQ dashboard).

---

## Laravel

Same `promphp/prometheus_client_php` package as plain PHP, wired as a route:

```php
// routes/web.php or routes/api.php
Route::get('/metrics', function () {
    $adapter = new Prometheus\Storage\Redis(['host' => config('database.redis.default.host')]);
    $registry = new Prometheus\CollectorRegistry($adapter);
    $renderer = new Prometheus\RenderTextFormat();
    return response($renderer->render($registry->getMetricFamilySamples()))
        ->header('Content-Type', Prometheus\RenderTextFormat::MIME_TYPE);
});
```

Use the **Redis storage adapter** here specifically — Laravel apps typically
run multiple PHP-FPM/Octane workers, and Redis is how counters aggregate
correctly across them (APCu is per-process, so each worker would report a
different partial count).

Track HTTP metrics via middleware:
```php
class PrometheusMiddleware
{
    public function handle($request, Closure $next)
    {
        $start = microtime(true);
        $response = $next($request);
        $duration = microtime(true) - $start;
        // record into a Histogram: http_request_duration_seconds
        return $response;
    }
}
```

For **queue worker metrics** (Laravel's own queue system, not BullMQ — that's
Node-only), hook `Queue::before`/`Queue::after`/`Queue::failing` listeners in
a service provider to increment Counters, giving you the same
`job_processed_total{status=success|failed}` shape used in the custom
dashboard from earlier in this conversation.

**Alternative:** `spatie/laravel-horizon` if you're on Redis queues — Horizon
has its own dashboard, and you can additionally scrape Redis directly via
`redis_exporter` to correlate queue depth with the dashboards here.

---

## Node.js (plain)

```bash
npm install prom-client
```

```js
const client = require('prom-client');
const register = new client.Registry();
client.collectDefaultMetrics({ register });

const httpDuration = new client.Histogram({
  name: 'http_request_duration_seconds',
  help: 'HTTP request duration',
  labelNames: ['method', 'route', 'status'],
  registers: [register],
});

app.get('/metrics', async (req, res) => {
  res.set('Content-Type', register.contentType);
  res.end(await register.metrics());
});
```

---

## NestJS

```bash
npm install @willsoto/nestjs-prometheus prom-client
```

```ts
// app.module.ts
import { PrometheusModule } from '@willsoto/nestjs-prometheus';

@Module({
  imports: [PrometheusModule.register()], // exposes GET /metrics by default
})
export class AppModule {}
```

Custom metrics via providers:
```ts
import { makeHistogramProvider } from '@willsoto/nestjs-prometheus';

providers: [
  makeHistogramProvider({
    name: 'http_request_duration_seconds',
    help: 'HTTP request duration',
    labelNames: ['method', 'route', 'status'],
  }),
]
```

Then inject with `@InjectMetric('http_request_duration_seconds')` in an
interceptor to time every request — this is the standard pattern and gives
you the same RED-metric shape as every other stack here, so the Fleet
Overview dashboard's panels work unmodified.

---

## BullMQ (no official Prometheus exporter)

BullMQ doesn't ship a Prometheus exporter, but its API exposes everything
needed. Minimal reference exporter using `prom-client`:

```js
const { Queue } = require('bullmq');
const client = require('prom-client');
const express = require('express');

const register = new client.Registry();
const queueDepth = new client.Gauge({
  name: 'bullmq_queue_messages',
  help: 'Number of jobs in a BullMQ queue by state',
  labelNames: ['queue', 'state'],
  registers: [register],
});

const queues = ['emails', 'invoices']; // list your queue names
const queueInstances = queues.map(name => new Queue(name, { connection: redisConfig }));

async function collect() {
  for (const q of queueInstances) {
    const counts = await q.getJobCounts('waiting', 'active', 'completed', 'failed', 'delayed');
    for (const [state, count] of Object.entries(counts)) {
      queueDepth.set({ queue: q.name, state }, count);
    }
  }
}

const app = express();
app.get('/metrics', async (req, res) => {
  await collect();
  res.set('Content-Type', register.contentType);
  res.end(await register.metrics());
});
app.listen(9538);
```

This gives you `bullmq_queue_messages{queue="emails", state="waiting"}` etc. —
matches the `rabbitmq_queue_messages`-style shape used in the custom queue
dashboard, just swap the metric name and labels there if you adopt this.

Run this as its own small process/container (not inside your NestJS app
necessarily, though it can live there too) — port 9538 is arbitrary, pick
one and keep it consistent across target files.

---

## Redis

**oliver006/redis_exporter** — the de facto standard:
```bash
docker run -d -p 9121:9121 \
  -e REDIS_ADDR=redis://your-redis-host:6379 \
  oliver006/redis_exporter:v1.93.0
```

One exporter per Redis instance (or per cluster node if clustered). Key
metrics: `redis_connected_clients`, `redis_used_memory_bytes`,
`redis_commands_processed_total`, `redis_keyspace_hits_total` /
`redis_keyspace_misses_total` (hit ratio — important if Redis is your cache
layer, not just a queue backend), `redis_evicted_keys_total`.

---

## RabbitMQ

Use the **native `rabbitmq_prometheus` plugin** (ships with RabbitMQ 3.8+),
not the older third-party `kbudde/rabbitmq_exporter` — one less moving part:

```bash
rabbitmq-plugins enable rabbitmq_prometheus
```

Metrics land on `:15692/metrics` directly from RabbitMQ itself — no separate
exporter process to run or maintain.

Key metrics: `rabbitmq_queue_messages_ready`, `rabbitmq_queue_messages_unacked`,
`rabbitmq_queue_consumers`, `rabbitmq_channel_messages_published_total`,
`rabbitmq_channel_messages_delivered_total`. Note: metric names differ
slightly from the older third-party exporter used in the earlier
`payments-api-custom-dashboard.json` (`rabbitmq_queue_messages` →
`rabbitmq_queue_messages_ready` here) — reconcile if migrating that dashboard
to the native plugin.

---

## ActiveMQ

No native Prometheus support. Use **jmx_exporter** against ActiveMQ's JMX
port (default 1099, must be explicitly enabled in `activemq.xml` /
`ACTIVEMQ_OPTS`):

```bash
ACTIVEMQ_OPTS="$ACTIVEMQ_OPTS -javaagent:/opt/jmx_exporter/jmx_prometheus_javaagent.jar=9405:/opt/jmx_exporter/activemq-config.yml"
```

`activemq-config.yml` needs explicit MBean-to-metric mappings (ActiveMQ's JMX
tree isn't auto-flattened cleanly like Spring's) — the community maintains
reference configs; search "jmx_exporter activemq config yaml" for a starting
point rather than writing the MBean patterns from scratch.

Key resulting metrics: queue size, enqueue/dequeue rates, consumer count —
same shape as RabbitMQ's, just different metric names (`org_apache_activemq_*`
prefix from the JMX mapping).

---

## Self-hosted PostgreSQL

**prometheus-community/postgres_exporter**, run alongside the DB (same host
or a sidecar container with network access):

```bash
docker run -d -p 9187:9187 \
  --add-host=host.docker.internal:host-gateway \
  -e DATA_SOURCE_URI="host.docker.internal:5432/postgres?sslmode=disable" \
  -e DATA_SOURCE_USER="monitoring_user" \
  -e DATA_SOURCE_PASS="PASSWORD" \
  ghcr.io/prometheus-community/postgres-exporter:v0.20.1
```

Create a dedicated **read-only monitoring role** rather than reusing an app
credential:
```sql
CREATE USER monitoring_user WITH PASSWORD 'PASSWORD';
GRANT pg_monitor TO monitoring_user;
```

Key metrics: `pg_up`, `pg_stat_database_numbackends` (connections),
`pg_stat_database_xact_commit`/`xact_rollback`, `pg_stat_activity_count`,
`pg_locks_count`, `pg_replication_lag_seconds` if you run replicas.

---

## Self-hosted MySQL

**prometheus/mysqld_exporter**:
```bash
docker run -d -p 9104:9104 \
  -v "$PWD/.my.cnf:/.my.cnf:ro" \
  --add-host=host.docker.internal:host-gateway \
  prom/mysqld-exporter:v0.20.0 \
  --mysqld.address=host.docker.internal:3306 --mysqld.username=monitoring_user
```

Create `.my.cnf` with a `[client]` section containing the monitoring username and password; keep that file out of version control. If the database is another container, use its Compose service name and shared network instead of `host.docker.internal`. The old `DATA_SOURCE_NAME` connection format was removed in mysqld_exporter 0.15.

Monitoring user needs limited grants:
```sql
CREATE USER 'monitoring_user'@'%' IDENTIFIED BY 'PASSWORD';
GRANT PROCESS, REPLICATION CLIENT, SELECT ON *.* TO 'monitoring_user'@'%';
```

Key metrics: `mysql_up`, `mysql_global_status_threads_connected`,
`mysql_global_status_slow_queries`, `mysql_global_status_questions` (query
rate), `mysql_global_status_innodb_row_lock_waits`.

---

## AWS RDS (PostgreSQL & MySQL)

RDS instances have no shell access, so `postgres_exporter`/`mysqld_exporter`
can't run "on" the database — instead, run them as their **own small
container/task** (ECS task, small EC2, or a container in your existing Docker
host) with the exporter configured to reach the RDS endpoint over the network:

```bash
docker run -d -p 9187:9187 \
  -e DATA_SOURCE_URI="your-db.xxxxx.rds.amazonaws.com:5432/postgres?sslmode=require" \
  -e DATA_SOURCE_USER="monitoring_user" \
  -e DATA_SOURCE_PASS="PASSWORD" \
  ghcr.io/prometheus-community/postgres-exporter:v0.20.1
```

Same monitoring-role setup as self-hosted, created via RDS's normal SQL
access (no OS-level install needed — RDS handles the exporter side, you're
just connecting as a client).

**Also add CloudWatch coverage** for storage-layer metrics the exporter can't
see (`FreeStorageSpace`, `ReadIOPS`/`WriteIOPS` at the EBS layer, RDS
Enhanced Monitoring if enabled): use **nerdswords/yet-another-cloudwatch-exporter
(yace)** — actively maintained, supports RDS out of the box via a YAML job
config referencing your RDS instance ARNs/tags. Runs as one process covering
many RDS instances, unlike postgres_exporter/mysqld_exporter which are
one-per-database.

This gives you two complementary views: `rds-postgresql`/`rds-mysql` jobs
(query-level: connections, slow queries, locks) and `cloudwatch-rds` job
(infrastructure-level: storage, IOPS, CPU credits if on burstable instance
classes).

---

## Dockerized applications (container-level, any stack)

**cAdvisor** — one per Docker host, sees every container regardless of what
runs inside:

> Optional and host-privileged: these host mounts reveal container and host
> metadata. Do not add this to the default stack unless you need container-level
> metrics and accept that access. Keep its UI bound to loopback or a trusted
> private network.

```yaml
# docker-compose.yml addition
cadvisor:
  image: ghcr.io/google/cadvisor:v0.60.6
  ports: ["127.0.0.1:8080:8080"]
  volumes:
    - /:/rootfs:ro
    - /var/run:/var/run:ro
    - /sys:/sys:ro
    - /var/lib/docker/:/var/lib/docker:ro
    - /dev/disk/:/dev/disk:ro
```

This is **additive** to every app-level exporter above, not a replacement —
cAdvisor sees CPU/memory/network/disk from the container runtime's
perspective; app exporters see it from inside the process. Use cAdvisor to
catch OOM-kills and container-level throttling that an app might not even be
aware happened to it.

---

## Host-level (bare VMs, not containers)

**node_exporter**, one per host:
```bash
docker run -d \
  --net=host --pid=host \
  -v "/:/host:ro,rslave" \
  quay.io/prometheus/node-exporter:v1.12.1 --path.rootfs=/host \
  --collector.filesystem.mount-points-exclude='^/(sys|proc|dev|host|etc)($$|/)'
```

The host-network example exposes port 9100 on the host's interfaces. Restrict it with a host firewall or private network, and do not publish unauthenticated exporter endpoints to the public internet.

The host-network example exposes port 9100 on the host's interfaces. Restrict it with a host firewall or private network, and do not publish unauthenticated exporter endpoints to the public internet.

Given your fleet is 60% self-hosted, this is worth deploying uniformly —
config management (Ansible/similar) rather than by hand once you're past a
handful of hosts.

---

## Frontend SPAs (Angular / Vue.js / React.js)

**These are not scraped by Prometheus.** They're static assets served by a
browser, with no persistent process exposing a `/metrics` endpoint (unless
you're server-side rendering, in which case the SSR Node process gets its
own Node.js exporter setup above).

Two separate concerns instead:
1. **Synthetic uptime/TLS checks** — the `blackbox-http` job already wired
   into `prometheus.yml`, using `prometheus/blackbox_exporter`. Confirms the
   app is reachable and serving 200s from the outside.
2. **Real User Monitoring (RUM) and JS error tracking** — out of Prometheus's
   scope entirely. Use Sentry, Grafana Faro, or similar for actual frontend
   performance/error visibility (page load time, JS exceptions, Core Web
   Vitals). Worth a separate conversation if you want this wired up —
   different tool, different data model (traces/events, not scraped metrics).
