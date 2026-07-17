// metrics.js
// Express middleware + /metrics endpoint using prom-client.
// Usage in server.js:
//
//   const { metricsMiddleware, metricsRoute } = require('./metrics');
//   app.use(metricsMiddleware);
//   app.get('/metrics', metricsRoute);

const client = require('prom-client');

// Default metrics: process CPU/memory, event loop lag, GC pause time —
// this is Node's own saturation signal (Section 5.2 of the report).
client.collectDefaultMetrics({ prefix: 'app_' });

const httpRequestsTotal = new client.Counter({
  name: 'http_requests_total',
  help: 'Total HTTP requests',
  labelNames: ['method', 'route', 'status'],
});

const httpRequestDuration = new client.Histogram({
  name: 'http_request_duration_seconds',
  help: 'HTTP request duration in seconds',
  labelNames: ['method', 'route'],
  buckets: [0.01, 0.05, 0.1, 0.3, 0.5, 1, 2, 5],
});

function metricsMiddleware(req, res, next) {
  const start = process.hrtime.bigint();

  res.on('finish', () => {
    const durationSeconds = Number(process.hrtime.bigint() - start) / 1e9;
    const route = req.route ? req.route.path : req.path;

    httpRequestsTotal.inc({ method: req.method, route, status: res.statusCode });
    httpRequestDuration.observe({ method: req.method, route }, durationSeconds);
  });

  next();
}

async function metricsRoute(req, res) {
  res.set('Content-Type', client.register.contentType);
  res.end(await client.register.metrics());
}

module.exports = { metricsMiddleware, metricsRoute, client };
