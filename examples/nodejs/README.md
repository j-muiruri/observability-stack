# Instrumenting a Node.js app

These files are a minimal, complete, runnable example — drop them into a real service by copying the
patterns (metrics middleware, logger, instrumentation.js) rather than the files verbatim if your app
already has its own structure.

## 1. Install packages

```bash
npm install express prom-client pino
npm install @opentelemetry/sdk-node @opentelemetry/auto-instrumentations-node \
            @opentelemetry/exporter-trace-otlp-http @opentelemetry/resources \
            @opentelemetry/semantic-conventions @opentelemetry/api
```

## 2. Run it

```bash
node -r ./instrumentation.js server.js
```

`instrumentation.js` must be loaded with `-r` (require) BEFORE `server.js` so it can patch Express/HTTP
before your app code requires them.

## 3. Sanity check

```bash
curl http://localhost:3001/            # generates a request + a trace
curl http://localhost:3001/metrics     # confirm http_requests_total appears
```

You should see log lines on stdout with `trace_id` in them (from `logger.js`'s `mixin()`), and the
`node-app` job in `prometheus/prometheus.yml` should show as UP in Prometheus within ~15s.

## 4. Event loop lag — the metric that matters most for Node

`client.collectDefaultMetrics()` in `metrics.js` already exposes `app_nodejs_eventloop_lag_seconds` and
friends. This is Node's saturation signal (Section 5.2 of the report) — watch it rise before CPU% does.
