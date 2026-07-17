// server.js — minimal example wiring metrics, logs and traces together.
// Run with:  node -r ./instrumentation.js server.js

const express = require('express');
const { metricsMiddleware, metricsRoute } = require('./metrics');
const { requestLogger } = require('./logger');

const app = express();

app.use(requestLogger);
app.use(metricsMiddleware);

app.get('/', (req, res) => {
  req.log.info('handled root request');
  res.send('ok');
});

app.get('/metrics', metricsRoute);

const port = process.env.PORT || 3001;
app.listen(port, () => console.log(`node-app listening on :${port}`));
