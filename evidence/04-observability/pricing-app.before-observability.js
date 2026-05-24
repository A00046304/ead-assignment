const express = require('express');
const crypto = require('crypto');

const app = express();
const PORT = process.env.PORT || 3001;
const DELAY_MS = Number(process.env.DELAY_MS || 0);

app.use(express.json({ limit: '50kb' }));

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

function getReqId(req) {
  return req.header('X-Request-Id') || crypto.randomUUID();
}

app.use((req, res, next) => {
  const rid = getReqId(req);
  const started = Date.now();

  req.requestId = rid;
  res.setHeader('X-Request-Id', rid);

  res.on('finish', () => {
    console.log(JSON.stringify({
      requestId: rid,
      service: 'pricing-fn',
      method: req.method,
      path: req.path,
      statusCode: res.statusCode,
      durationMs: Date.now() - started,
      outcome: res.statusCode >= 400 ? 'rejected' : 'success'
    }));
  });

  next();
});

app.get('/health', (req, res) => {
  res.json({ ok: true, service: 'pricing-fn', delayMs: DELAY_MS, requestId: req.requestId });
});

app.post('/price', async (req, res) => {
  if (DELAY_MS > 0) await sleep(DELAY_MS);

  const { subtotal } = req.body;
  const s = Number(subtotal);

  if (!Number.isFinite(s) || s < 0) {
    return res.status(400).json({
      error: 'subtotal must be a non-negative number',
      requestId: req.requestId
    });
  }

  const taxRate = 0.23;
  const tax = Number((s * taxRate).toFixed(2));
  const total = Number((s + tax).toFixed(2));

  return res.json({
    subtotal: s,
    taxRate,
    tax,
    total,
    requestId: req.requestId
  });
});

app.listen(PORT, () => {
  console.log(`pricing-fn on ${PORT}`);
});
