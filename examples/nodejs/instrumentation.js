// instrumentation.js
// Must be required BEFORE your app code so auto-instrumentation can patch
// modules (http, express, pg, mysql2, etc.) before they're first required.
//
//   node -r ./instrumentation.js server.js
//
// or in package.json:
//   "scripts": { "start": "node -r ./instrumentation.js server.js" }

const { NodeSDK } = require('@opentelemetry/sdk-node');
const { getNodeAutoInstrumentations } = require('@opentelemetry/auto-instrumentations-node');
const { OTLPTraceExporter } = require('@opentelemetry/exporter-trace-otlp-http');
const { Resource } = require('@opentelemetry/resources');
const { SemanticResourceAttributes } = require('@opentelemetry/semantic-conventions');

const sdk = new NodeSDK({
  resource: new Resource({
    [SemanticResourceAttributes.SERVICE_NAME]: process.env.OTEL_SERVICE_NAME || 'node-app',
    [SemanticResourceAttributes.DEPLOYMENT_ENVIRONMENT]: process.env.NODE_ENV || 'local',
  }),
  traceExporter: new OTLPTraceExporter({
    // 4320 = Alloy's host-mapped OTLP HTTP port (docker-compose.yml)
    url: process.env.OTEL_EXPORTER_OTLP_ENDPOINT || 'http://localhost:4320/v1/traces',
  }),
  instrumentations: [getNodeAutoInstrumentations()],
});

sdk.start();

process.on('SIGTERM', () => sdk.shutdown().finally(() => process.exit(0)));
