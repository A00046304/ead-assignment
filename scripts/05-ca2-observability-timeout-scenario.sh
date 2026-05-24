#!/usr/bin/env bash
set -e

NAMESPACE="${NAMESPACE:-lab4}"
OUT_DIR="evidence/04-observability"
REQ_ID="ca2-timeout-demo-001"

mkdir -p "$OUT_DIR"

echo "======================================"
echo "CA2 Observability Scenario"
echo "Inventory delay -> checkout timeout"
echo "Namespace: $NAMESPACE"
echo "Request ID: $REQ_ID"
echo "======================================"

echo ""
echo "1. Capturing metrics before failure scenario..."
curl -s http://localhost:3003/metrics | tee "$OUT_DIR/metrics-before-timeout.json" || true

echo ""
echo "2. Making inventory-fn slow using DELAY_MS=3000..."
kubectl set env deployment/inventory-fn DELAY_MS=3000 -n "$NAMESPACE"
kubectl rollout status deployment/inventory-fn -n "$NAMESPACE" --timeout=180s

echo ""
echo "3. Confirming inventory pod is running..."
kubectl get pods -n "$NAMESPACE" -l app=inventory-fn -o wide | tee "$OUT_DIR/inventory-delay-pod-state.txt"

echo ""
echo "4. Sending checkout request that should timeout because checkout TIMEOUT_MS is 1500ms..."
curl -i --max-time 10 \
  -H "Content-Type: application/json" \
  -H "X-Request-Id: $REQ_ID" \
  -d '{"sku":1,"subtotal":100}' \
  http://localhost/api/checkout | tee "$OUT_DIR/checkout-timeout-response.txt" || true

echo ""
echo "5. Capturing checkout logs with timeout evidence..."
kubectl logs -n "$NAMESPACE" deployment/checkout-fn --tail=80 | tee "$OUT_DIR/checkout-logs-after-timeout.txt"

echo ""
echo "6. Capturing inventory logs with matching request ID..."
kubectl logs -n "$NAMESPACE" deployment/inventory-fn --tail=80 | tee "$OUT_DIR/inventory-logs-after-timeout.txt"

echo ""
echo "7. Capturing metrics after timeout..."
curl -s http://localhost:3003/metrics | tee "$OUT_DIR/metrics-after-timeout.json" || true

echo ""
echo "8. Restoring inventory delay back to normal..."
kubectl set env deployment/inventory-fn DELAY_MS=0 -n "$NAMESPACE"
kubectl rollout status deployment/inventory-fn -n "$NAMESPACE" --timeout=180s

echo ""
echo "9. Sending recovery checkout request..."
curl -i --max-time 10 \
  -H "Content-Type: application/json" \
  -H "X-Request-Id: ca2-timeout-recovery-001" \
  -d '{"sku":1,"subtotal":100}' \
  http://localhost/api/checkout | tee "$OUT_DIR/checkout-recovery-response.txt" || true

echo ""
echo "10. Capturing final metrics after recovery..."
curl -s http://localhost:3003/metrics | tee "$OUT_DIR/metrics-after-recovery.json" || true

echo ""
echo "======================================"
echo "Observability scenario complete."
echo "Evidence saved in $OUT_DIR"
echo "======================================"
