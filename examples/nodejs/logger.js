// logger.js
// Structured JSON logging with the active OpenTelemetry trace_id attached to
// every line, so a log line in Loki can link straight to its trace in Tempo
// (see grafana/provisioning/datasources/datasources.yml -> derivedFields).

const pino = require('pino');
const { trace, context } = require('@opentelemetry/api');

const logger = pino({
  level: process.env.LOG_LEVEL || 'info',
  base: { service: process.env.OTEL_SERVICE_NAME || 'node-app' },
  mixin() {
    const span = trace.getSpan(context.active());
    if (!span) return {};
    const { traceId, spanId } = span.spanContext();
    return { trace_id: traceId, span_id: spanId };
  },
});

// Express middleware: attaches a per-request child logger with request_id.
function requestLogger(req, res, next) {
  req.log = logger.child({ request_id: req.headers['x-request-id'] || req.id });
  next();
}

module.exports = { logger, requestLogger };
