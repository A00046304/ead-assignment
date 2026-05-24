#!/usr/bin/env bash
set -e

NAMESPACE="${NAMESPACE:-lab4}"
OUT_DIR="evidence/04-observability"

mkdir -p "$OUT_DIR"

echo "======================================"
echo "CA2 Step 4: Observability implementation"
echo "Namespace: $NAMESPACE"
echo "======================================"

echo ""
echo "1. Backing up current service code..."
cp compose/checkout-fn/app.js "$OUT_DIR/checkout-app.before-observability.js"
cp compose/pricing-fn/app.js "$OUT_DIR/pricing-app.before-observability.js"
cp compose/inventory-fn/app.js "$OUT_DIR/inventory-app.before-observability.js"

echo ""
echo "2. Updating checkout-fn with metrics and completion logs..."

cat > compose/checkout-fn/app.js <<'APP'
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
APP

echo ""
echo "3. Updating pricing-fn with completion logs..."

cat > compose/pricing-fn/app.js <<'APP'
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
APP

echo ""
echo "4. Updating inventory-fn with completion logs..."

cat > compose/inventory-fn/app.js <<'APP'
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
  const started = Date.now();

  req.requestId = rid;
  res.setHeader('X-Request-Id', rid);

  res.on('finish', () => {
    console.log(JSON.stringify({
      requestId: rid,
      service: 'inventory-fn',
      method: req.method,
      path: req.path,
      statusCode: res.statusCode,
      durationMs: Date.now() - started,
      outcome: res.statusCode >= 400 ? 'rejected' : 'success'
    }));
  });

  next();
});

const inventory = {
  1: { inStock: true },
  2: { inStock: true },
  3: { inStock: false }
};

app.get('/health', (req, res) => {
  res.json({ ok: true, service: 'inventory-fn', delayMs: DELAY_MS, requestId: req.requestId });
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
APP

echo ""
echo "5. Building updated images..."
docker build -t lab4/checkout-fn:v6-ca2 compose/checkout-fn
docker build -t lab4/pricing-fn:v3-ca2 compose/pricing-fn
docker build -t lab4/inventory-fn:v3-ca2 compose/inventory-fn

echo ""
echo "6. Importing images into K3s containerd..."
docker save lab4/checkout-fn:v6-ca2 | sudo k3s ctr images import -
docker save lab4/pricing-fn:v3-ca2 | sudo k3s ctr images import -
docker save lab4/inventory-fn:v3-ca2 | sudo k3s ctr images import -

echo ""
echo "7. Updating Kubernetes deployments..."
kubectl set image deployment/checkout-fn checkout-fn=lab4/checkout-fn:v6-ca2 -n "$NAMESPACE"
kubectl set image deployment/pricing-fn pricing-fn=lab4/pricing-fn:v3-ca2 -n "$NAMESPACE"
kubectl set image deployment/inventory-fn inventory-fn=lab4/inventory-fn:v3-ca2 -n "$NAMESPACE"

echo ""
echo "8. Waiting for rollouts..."
kubectl rollout status deployment/pricing-fn -n "$NAMESPACE" --timeout=180s
kubectl rollout status deployment/inventory-fn -n "$NAMESPACE" --timeout=180s
kubectl rollout status deployment/checkout-fn -n "$NAMESPACE" --timeout=180s

echo ""
echo "9. Capturing observability implementation evidence..."

{
  echo "---- Pods after observability update ----"
  kubectl get pods -n "$NAMESPACE" -o wide

  echo ""
  echo "---- Images now used ----"
  kubectl get deploy checkout-fn -n "$NAMESPACE" -o jsonpath='{.spec.template.spec.containers[0].image}{"\n"}'
  kubectl get deploy pricing-fn -n "$NAMESPACE" -o jsonpath='{.spec.template.spec.containers[0].image}{"\n"}'
  kubectl get deploy inventory-fn -n "$NAMESPACE" -o jsonpath='{.spec.template.spec.containers[0].image}{"\n"}'

  echo ""
  echo "---- Metrics endpoint present in source ----"
  grep -n "metrics\\|durationMs\\|dependencyTimeoutTotal\\|databaseWriteFailureTotal" compose/checkout-fn/app.js | head -n 40

} | tee "$OUT_DIR/observability-implementation-evidence.txt"

echo ""
echo "======================================"
echo "Observability implementation completed."
echo "======================================"
