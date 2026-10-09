# Performance and capacity guide

This is a single-host self-hosted stack, not a capacity-tested sizing profile. The Compose CPU and memory limits are fixed example ceilings; inspect `docker-compose.yml` and adjust them to the measured host and workload. Leave additional host memory for Docker, the OS, and applications that generate telemetry. The limits can throttle sustained ingestion or queries, while setting them too high can starve the host.

## Start with evidence

Before changing settings, record a representative baseline while exercising the app:

- Prometheus: active series, samples ingested per second, scrape duration/failures, query latency, TSDB disk usage, process CPU/RSS.
- Loki: bytes/lines ingested, stream and label counts, query duration, process CPU/RSS, volume growth.
- Tempo: spans/traces ingested, rejected spans, query latency, process CPU/RSS, volume growth.
- Alloy: receiver/exporter accepted, refused, and failed telemetry; queue size and memory; CPU/RSS.
- Host: CPU saturation, available memory, disk capacity and I/O latency.

Compare the same time window and request mix before and after each change. Optimize the source of the bottleneck, not every service at once.

## Practical tuning order

1. **Control cardinality first.** Keep metric labels to bounded dimensions such as service, method, route template, status class, and environment. Do not use raw URL paths, IDs, trace IDs, user IDs, or arbitrary exception text as metric labels. The Node.js sample maps unmatched requests to one `unmatched` route label to avoid a new series per URL.
2. **Reduce unnecessary collection.** Remove unused target files and exporters, lower the metrics exposed by exporters, and avoid scraping the same metric endpoint in multiple jobs. The checked-in global scrape interval is 1 minute; a longer interval lowers scrape traffic and storage at the cost of alert/dashboard freshness. Choose intervals per service based on the required detection latency.
3. **Set a retention and disk budget.** Prometheus retains 7 days in the checked-in Compose command. Monitor actual volume growth; Loki (14 days) and Tempo (7 days) also consume disk independently. Reserve free disk for WALs, compaction, and temporary files rather than sizing volumes exactly to the retention estimate.
4. **Avoid oversized queries.** Scope dashboards to the service and time range, use recording rules for repeatedly evaluated aggregations, and inspect slow queries before raising resource limits. Avoid broad high-cardinality `by(...)` groupings.
5. **Right-size CPU and memory.** If the process is constantly at its CPU ceiling, adjust its Compose limit or reduce ingest/query work. If it approaches its memory ceiling or restarts, investigate cardinality, queues, and workload peaks first. Raising a ceiling without enough host memory can make the whole machine slower.
6. **Re-test the whole data path.** Confirm metrics, logs, and traces are still accepted and queryable after each change; verify dashboards and alert rules as well as container state.

## Storage and topology trade-offs

Prometheus, Loki, and Tempo use local single-node storage. Named volumes persist across container replacement but do not provide shared access, replication, or high availability. Increasing retention increases disk requirements and may increase query/compaction work. Plan backups, restore tests, storage capacity, and HA topology for the measured workload rather than inferring them from these examples.

This repository does not include Mimir. Prometheus's remote-write receiver is enabled for Tempo's metrics-generator output; it should not be treated as an authenticated, externally exposed metrics-ingestion service.
