const express = require('express');
const crypto = require('crypto');
const { Pool } = require('pg');

const app = express();
const PORT = process.env.PORT || 3003;

app.use(express.json({ limit: '50kb' }));

const PRICING_URL = process.env.PRICING_URL || 'http://pricing-svc:3001';
const INVENTORY_URL = process.env.INVENTORY_URL || 'http://inventory-svc:3002';
const TIMEOUT_MS = Number(process.env.TIMEOUT_MS || 1500);

function requiredEnv(name) {
  const value = process.env[name];
  if (!value) {
    throw new Error(`Missing required environment variable: ${name}`);
  }
  return value;
}

const DB_HOST = process.env.DB_HOST || 'postgres-svc';
const DB_PORT = Number(process.env.DB_PORT || 5432);
const DB_NAME = requiredEnv('DB_NAME');
const DB_USER = requiredEnv('DB_USER');
const DB_PASSWORD = requiredEnv('DB_PASSWORD');

const pool = new Pool({
  host: DB_HOST,
  port: DB_PORT,
  database: DB_NAME,
  user: DB_USER,
  password: DB_PASSWORD
});

const metrics = {
  service: 'checkout-fn',
  startedAt: new Date().toISOString(),
  checkoutRequestsTotal: 0,
  checkoutSuccessTotal: 0,
  badRequestTotal: 0,
  outOfStockTotal: 0,
  dependencyFailureTotal: 0,
  dependencyTimeoutTotal: 0,
  databaseWriteFailureTotal: 0,
  lastRequest: null
};

function updateLastRequest(req, statusCode, durationMs, outcome, reason) {
  metrics.lastRequest = {
    requestId: req.requestId,
    method: req.method,
    path: req.path,
    statusCode,
    durationMs,
    outcome,
    reason: reason || null,
    timestamp: new Date().toISOString()
  };
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
    const durationMs = Date.now() - started;
    const outcome =
      res.statusCode >= 500 ? 'error' :
      res.statusCode >= 400 ? 'rejected' :
      'success';

    console.log(JSON.stringify({
      requestId: rid,
      service: 'checkout-fn',
      method: req.method,
      path: req.path,
      statusCode: res.statusCode,
      durationMs,
      outcome
    }));
  });

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

function isAbortError(err) {
  return err && (err.name === 'AbortError' || /abort|timeout/i.test(err.message));
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
    return res.json({ ok: true, service: 'checkout-fn', db: 'up', requestId: req.requestId });
  } catch (err) {
    return res.status(500).json({ ok: false, service: 'checkout-fn', db: 'down', requestId: req.requestId });
  }
});

// Internal metrics endpoint. This is not exposed through the public gateway.
app.get('/metrics', (req, res) => {
  res.json(metrics);
});

app.get('/prometheus', (req, res) => {
  res.set('Content-Type', 'text/plain; version=0.0.4');

  res.send(`
# HELP checkout_requests_total Total checkout requests received
# TYPE checkout_requests_total counter
checkout_requests_total ${metrics.checkoutRequestsTotal}

# HELP checkout_success_total Successful checkout requests
# TYPE checkout_success_total counter
checkout_success_total ${metrics.checkoutSuccessTotal}

# HELP checkout_bad_request_total Bad checkout requests
# TYPE checkout_bad_request_total counter
checkout_bad_request_total ${metrics.badRequestTotal}

# HELP checkout_out_of_stock_total Out of stock checkout responses
# TYPE checkout_out_of_stock_total counter
checkout_out_of_stock_total ${metrics.outOfStockTotal}

# HELP checkout_dependency_failure_total Dependency failure count
# TYPE checkout_dependency_failure_total counter
checkout_dependency_failure_total ${metrics.dependencyFailureTotal}

# HELP checkout_dependency_timeout_total Dependency timeout count
# TYPE checkout_dependency_timeout_total counter
checkout_dependency_timeout_total ${metrics.dependencyTimeoutTotal}

# HELP checkout_database_write_failure_total Database write failure count
# TYPE checkout_database_write_failure_total counter
checkout_database_write_failure_total ${metrics.databaseWriteFailureTotal}
`.trim() + '\n');
});

async function handleCheckout(req, res) {
  const started = Date.now();
  metrics.checkoutRequestsTotal += 1;

  const { sku, subtotal } = req.body;
  const skuNum = Number(sku);
  const subNum = Number(subtotal);

  if (!Number.isInteger(skuNum)) {
    metrics.badRequestTotal += 1;
    updateLastRequest(req, 400, Date.now() - started, 'bad_request', 'sku must be an integer');
    return res.status(400).json({ error: 'sku must be an integer', requestId: req.requestId });
  }

  if (!Number.isFinite(subNum) || subNum < 0) {
    metrics.badRequestTotal += 1;
    updateLastRequest(req, 400, Date.now() - started, 'bad_request', 'subtotal must be non-negative');
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
      metrics.dependencyFailureTotal += 1;
      updateLastRequest(req, 502, Date.now() - started, 'dependency_failure', body.error || 'pricing failed');
      return res.status(502).json({ error: body.error || 'pricing failed', requestId: req.requestId });
    }

    if (!stockRes.ok) {
      const body = await stockRes.json().catch(() => ({}));
      metrics.dependencyFailureTotal += 1;
      updateLastRequest(req, 502, Date.now() - started, 'dependency_failure', body.error || 'inventory failed');
      return res.status(502).json({ error: body.error || 'inventory failed', requestId: req.requestId });
    }

    const price = await priceRes.json();
    const stock = await stockRes.json();

    if (!stock.inStock) {
      metrics.outOfStockTotal += 1;
      updateLastRequest(req, 409, Date.now() - started, 'out_of_stock', 'inventory reported no stock');
      return res.status(409).json({
        error: 'out of stock',
        sku: skuNum,
        price,
        requestId: req.requestId
      });
    }

    let saved;
    try {
      saved = await saveOrder({
        sku: skuNum,
        subtotal: price.subtotal,
        tax: price.tax,
        total: price.total,
        status: 'SUCCESS',
        requestId: req.requestId
      });
    } catch (dbErr) {
      metrics.databaseWriteFailureTotal += 1;
      console.error(JSON.stringify({
        requestId: req.requestId,
        service: 'checkout-fn',
        event: 'database_write_failed',
        error: dbErr.message
      }));
      updateLastRequest(req, 503, Date.now() - started, 'database_failure', 'order write failed');
      return res.status(503).json({ error: 'database write failed', requestId: req.requestId });
    }

    metrics.checkoutSuccessTotal += 1;
    updateLastRequest(req, 200, Date.now() - started, 'success', null);

    return res.json({
      ok: true,
      orderId: saved.id,
      sku: skuNum,
      price,
      stock,
      requestId: req.requestId
    });
  } catch (err) {
    const timedOut = isAbortError(err);

    if (timedOut) {
      metrics.dependencyTimeoutTotal += 1;
    } else {
      metrics.dependencyFailureTotal += 1;
    }

    console.error(JSON.stringify({
      requestId: req.requestId,
      service: 'checkout-fn',
      event: timedOut ? 'dependency_timeout' : 'dependency_unavailable',
      timeoutMs: TIMEOUT_MS,
      durationMs: Date.now() - started,
      error: err.message
    }));

    updateLastRequest(
      req,
      503,
      Date.now() - started,
      timedOut ? 'dependency_timeout' : 'dependency_unavailable',
      err.message
    );

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
