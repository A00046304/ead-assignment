const express = require('express');
const crypto = require('crypto');

const app = express();

const PORT = process.env.PORT || 3002;
const DELAY_MS = Number(process.env.DELAY_MS || 0);

app.use(express.json({ limit: '50kb' }));

const metrics = {
  inventoryRequestsTotal: 0,
  inventorySuccessTotal: 0,
  inventoryErrorTotal: 0,
  inventoryOutOfStockTotal: 0
};

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

function getReqId(req) {
  return req.header('X-Request-Id') || crypto.randomUUID();
}

function getStockForSku(sku) {
  const numericSku = Number(sku);

  if (!Number.isFinite(numericSku) || numericSku <= 0) {
    return {
      valid: false,
      error: 'sku must be a positive number'
    };
  }

  if (numericSku === 3) {
    return {
      valid: true,
      sku: numericSku,
      inStock: false
    };
  }

  return {
    valid: true,
    sku: numericSku,
    inStock: true
  };
}

app.use((req, res, next) => {
  const rid = getReqId(req);
  const started = Date.now();

  req.requestId = rid;
  res.setHeader('X-Request-Id', rid);

  if (req.path !== '/health' && req.path !== '/prometheus') {
    metrics.inventoryRequestsTotal++;
  }

  res.on('finish', () => {
    const isBusinessRequest = req.path !== '/health' && req.path !== '/prometheus';

    if (isBusinessRequest) {
      if (res.statusCode >= 200 && res.statusCode < 400) {
        metrics.inventorySuccessTotal++;
      } else {
        metrics.inventoryErrorTotal++;
      }
    }

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

app.get('/health', (req, res) => {
  res.json({
    ok: true,
    service: 'inventory-fn',
    delayMs: DELAY_MS,
    requestId: req.requestId
  });
});

app.get('/prometheus', (req, res) => {
  res.set('Content-Type', 'text/plain; version=0.0.4');

  res.send(`
# HELP inventory_requests_total Total inventory business requests received
# TYPE inventory_requests_total counter
inventory_requests_total ${metrics.inventoryRequestsTotal}

# HELP inventory_success_total Successful inventory business requests
# TYPE inventory_success_total counter
inventory_success_total ${metrics.inventorySuccessTotal}

# HELP inventory_error_total Inventory error responses
# TYPE inventory_error_total counter
inventory_error_total ${metrics.inventoryErrorTotal}

# HELP inventory_out_of_stock_total Inventory out-of-stock responses
# TYPE inventory_out_of_stock_total counter
inventory_out_of_stock_total ${metrics.inventoryOutOfStockTotal}
`.trim() + '\n');
});

app.get('/stock/:sku', async (req, res) => {
  if (DELAY_MS > 0) {
    await sleep(DELAY_MS);
  }

  const stock = getStockForSku(req.params.sku);

  if (!stock.valid) {
    return res.status(400).json({
      error: stock.error,
      requestId: req.requestId
    });
  }

  if (!stock.inStock) {
    metrics.inventoryOutOfStockTotal++;
  }

  return res.json({
    sku: stock.sku,
    inStock: stock.inStock,
    requestId: req.requestId
  });
});

app.post('/stock', async (req, res) => {
  if (DELAY_MS > 0) {
    await sleep(DELAY_MS);
  }

  const stock = getStockForSku(req.body.sku);

  if (!stock.valid) {
    return res.status(400).json({
      error: stock.error,
      requestId: req.requestId
    });
  }

  if (!stock.inStock) {
    metrics.inventoryOutOfStockTotal++;
  }

  return res.json({
    sku: stock.sku,
    inStock: stock.inStock,
    requestId: req.requestId
  });
});

app.get('/inventory/:sku', async (req, res) => {
  if (DELAY_MS > 0) {
    await sleep(DELAY_MS);
  }

  const stock = getStockForSku(req.params.sku);

  if (!stock.valid) {
    return res.status(400).json({
      error: stock.error,
      requestId: req.requestId
    });
  }

  if (!stock.inStock) {
    metrics.inventoryOutOfStockTotal++;
  }

  return res.json({
    sku: stock.sku,
    inStock: stock.inStock,
    requestId: req.requestId
  });
});

app.post('/inventory', async (req, res) => {
  if (DELAY_MS > 0) {
    await sleep(DELAY_MS);
  }

  const stock = getStockForSku(req.body.sku);

  if (!stock.valid) {
    return res.status(400).json({
      error: stock.error,
      requestId: req.requestId
    });
  }

  if (!stock.inStock) {
    metrics.inventoryOutOfStockTotal++;
  }

  return res.json({
    sku: stock.sku,
    inStock: stock.inStock,
    requestId: req.requestId
  });
});

app.listen(PORT, () => {
  console.log(`inventory-fn on ${PORT}`);
});
