const express = require('express');
const crypto = require('crypto');

const app = express();

const PORT = process.env.PORT || 3001;
const DELAY_MS = Number(process.env.DELAY_MS || 0);

app.use(express.json({ limit: '50kb' }));

const metrics = {
  pricingRequestsTotal: 0,
  pricingSuccessTotal: 0,
  pricingErrorTotal: 0
};

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

  if (req.path !== '/health' && req.path !== '/prometheus') {
    metrics.pricingRequestsTotal++;
  }

  res.on('finish', () => {
    const isBusinessRequest = req.path !== '/health' && req.path !== '/prometheus';

    if (isBusinessRequest) {
      if (res.statusCode >= 200 && res.statusCode < 400) {
        metrics.pricingSuccessTotal++;
      } else {
        metrics.pricingErrorTotal++;
      }
    }

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
  res.json({
    ok: true,
    service: 'pricing-fn',
    delayMs: DELAY_MS,
    requestId: req.requestId
  });
});

app.get('/prometheus', (req, res) => {
  res.set('Content-Type', 'text/plain; version=0.0.4');

  res.send(`
# HELP pricing_requests_total Total pricing business requests received
# TYPE pricing_requests_total counter
pricing_requests_total ${metrics.pricingRequestsTotal}

# HELP pricing_success_total Successful pricing business requests
# TYPE pricing_success_total counter
pricing_success_total ${metrics.pricingSuccessTotal}

# HELP pricing_error_total Pricing error responses
# TYPE pricing_error_total counter
pricing_error_total ${metrics.pricingErrorTotal}
`.trim() + '\n');
});

app.post('/price', async (req, res) => {
  if (DELAY_MS > 0) {
    await sleep(DELAY_MS);
  }

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
