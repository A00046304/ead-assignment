const express = require('express');
const crypto = require('crypto');
const { Pool } = require('pg');

const app = express();
const PORT = process.env.PORT || 3003;

app.use(express.json({ limit: '50kb' }));

const PRICING_URL = process.env.PRICING_URL || 'http://pricing-fn:3001';
const INVENTORY_URL = process.env.INVENTORY_URL || 'http://inventory-fn:3002';
const TIMEOUT_MS = Number(process.env.TIMEOUT_MS || 1500);

const DB_HOST = process.env.DB_HOST || 'postgres-svc';
const DB_PORT = Number(process.env.DB_PORT || 5432);
const DB_NAME = process.env.DB_NAME || 'shop';
const DB_USER = process.env.DB_USER || 'appuser';
const DB_PASSWORD = process.env.DB_PASSWORD || 'apppass';

const pool = new Pool({
  host: DB_HOST,
  port: DB_PORT,
  database: DB_NAME,
  user: DB_USER,
  password: DB_PASSWORD
});

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

function withTimeout(ms) {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), ms);
  return {
    signal: controller.signal,
    cancel: () => clearTimeout(timer)
  };
}

async function saveOrder({ sku, subtotal, tax, total, status, requestId }) {
  const sql = `
    INSERT INTO orders (sku, subtotal, tax, total, status, request_id)
    VALUES ($1, $2, $3, $4, $5, $6)
    RETURNING id
  `;
  const values = [sku, subtotal, tax, total, status, requestId];
  const result = await pool.query(sql, values);
  return result.rows[0];
}

app.get('/health', async (req, res) => {
  try {
    await pool.query('SELECT 1');
    res.json({ ok: true, service: 'checkout-fn', db: 'up', requestId: req.requestId });
  } catch (err) {
    res.status(500).json({ ok: false, service: 'checkout-fn', db: 'down', requestId: req.requestId });
  }
});

async function handleCheckout(req, res) {
  const { sku, subtotal } = req.body;

  const skuNum = Number(sku);
  const subNum = Number(subtotal);

  if (!Number.isInteger(skuNum)) {
    return res.status(400).json({ error: 'sku must be an integer', requestId: req.requestId });
  }

  if (!Number.isFinite(subNum) || subNum < 0) {
    return res.status(400).json({ error: 'subtotal must be a non-negative number', requestId: req.requestId });
  }

  const pricingCtl = withTimeout(TIMEOUT_MS);
  const inventoryCtl = withTimeout(TIMEOUT_MS);

  try {
    const [priceRes, stockRes] = await Promise.all([
      fetch(`${PRICING_URL}/price`, {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          'X-Request-Id': req.requestId
        },
        body: JSON.stringify({ subtotal: subNum }),
        signal: pricingCtl.signal
      }),
      fetch(`${INVENTORY_URL}/stock/${skuNum}`, {
        headers: {
          'X-Request-Id': req.requestId
        },
        signal: inventoryCtl.signal
      })
    ]);

    if (!priceRes.ok) {
      const body = await priceRes.json().catch(() => ({}));
      return res.status(502).json({
        error: body.error || 'pricing failed',
        requestId: req.requestId
      });
    }

    if (!stockRes.ok) {
      const body = await stockRes.json().catch(() => ({}));
      return res.status(502).json({
        error: body.error || 'inventory failed',
        requestId: req.requestId
      });
    }

    const price = await priceRes.json();
    const stock = await stockRes.json();

    if (!stock.inStock) {
      return res.status(409).json({
        error: 'out of stock',
        sku: skuNum,
        price,
        requestId: req.requestId
      });
    }

    const saved = await saveOrder({
      sku: skuNum,
      subtotal: price.subtotal,
      tax: price.tax,
      total: price.total,
      status: 'SUCCESS',
      requestId: req.requestId
    });

    return res.json({
      ok: true,
      orderId: saved.id,
      sku: skuNum,
      price,
      stock,
      requestId: req.requestId
    });
  } catch (err) {
    console.error(`[rid=${req.requestId}] checkout error:`, err.message);
    return res.status(503).json({
      error: 'dependency timeout/unavailable',
      requestId: req.requestId
    });
  } finally {
    pricingCtl.cancel();
    inventoryCtl.cancel();
  }
}

app.post('/checkout', handleCheckout);
app.post('/api/checkout', handleCheckout);

app.listen(PORT, () => {
  console.log(`checkout-fn on ${PORT}`);
});
