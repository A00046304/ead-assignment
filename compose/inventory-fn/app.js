const express = require('express');
const crypto = require('crypto');

const app = express();
const PORT = process.env.PORT || 3002;
const DELAY_MS = Number(process.env.DELAY_MS || 0);

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

function getReqId(req) {
  return req.header('X-Request-Id') || crypto.randomUUID();
}

app.use((req, res, next) => {
  const rid = getReqId(req);
  req.requestId = rid;
  res.setHeader('X-Request-Id', rid);
  console.log(`[rid=${rid}] ${req.method} ${req.path}`);
  next();
});

const inventory = {
  1: { inStock: true },
  2: { inStock: true },
  3: { inStock: false }
};

app.get('/health', (req, res) => {
  res.json({ ok: true, service: 'inventory-fn', requestId: req.requestId });
});

app.get('/stock/:sku', async (req, res) => {
  if (DELAY_MS > 0) await sleep(DELAY_MS);

  const sku = Number(req.params.sku);

  if (!Number.isInteger(sku)) {
    return res.status(400).json({
      error: 'sku must be an integer',
      requestId: req.requestId
    });
  }

  const item = inventory[sku];
  if (!item) {
    return res.status(404).json({
      error: 'unknown sku',
      requestId: req.requestId
    });
  }

  return res.json({
    sku,
    inStock: item.inStock,
    requestId: req.requestId
  });
});

app.listen(PORT, () => {
  console.log(`inventory-fn on ${PORT}`);
});
