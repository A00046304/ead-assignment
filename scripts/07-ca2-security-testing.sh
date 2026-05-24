#!/usr/bin/env bash
set -e

NAMESPACE="${NAMESPACE:-lab4}"
OUT_DIR="evidence/06-security-testing"

mkdir -p "$OUT_DIR"

echo "======================================"
echo "CA2 Step 8: Security testing"
echo "Namespace: $NAMESPACE"
echo "Output: $OUT_DIR"
echo "======================================"

echo ""
echo "1. Capturing current deployment state..."
kubectl get deploy,pods,svc,ingress,networkpolicy -n "$NAMESPACE" -o wide \
  | tee "$OUT_DIR/current-state-before-security-tests.txt"

echo ""
echo "2. Running Trivy image scans using Docker..."
echo "This scans the local images built for the CA2 version."

docker run --rm \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -v "$PWD/$OUT_DIR:/out" \
  aquasec/trivy:latest image \
  --severity HIGH,CRITICAL \
  --no-progress \
  --format table \
  -o /out/trivy-checkout-fn.txt \
  lab4/checkout-fn:v6-ca2 || true

docker run --rm \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -v "$PWD/$OUT_DIR:/out" \
  aquasec/trivy:latest image \
  --severity HIGH,CRITICAL \
  --no-progress \
  --format table \
  -o /out/trivy-pricing-fn.txt \
  lab4/pricing-fn:v3-ca2 || true

docker run --rm \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -v "$PWD/$OUT_DIR:/out" \
  aquasec/trivy:latest image \
  --severity HIGH,CRITICAL \
  --no-progress \
  --format table \
  -o /out/trivy-inventory-fn.txt \
  lab4/inventory-fn:v3-ca2 || true

echo ""
echo "3. Running Checkov Kubernetes manifest posture scan..."

docker run --rm \
  -v "$PWD:/repo" \
  bridgecrew/checkov:latest \
  -d /repo/k8s/manifests \
  --framework kubernetes \
  --output cli \
  > "$OUT_DIR/checkov-k8s-manifests.txt" || true

echo ""
echo "4. Running ZAP baseline against public gateway..."

docker run --rm \
  --network host \
  -v "$PWD/$OUT_DIR:/zap/wrk" \
  ghcr.io/zaproxy/zaproxy:stable \
  zap-baseline.py \
  -t http://localhost/ \
  -r zap-baseline-report.html \
  -w zap-baseline-warnings.md \
  -J zap-baseline-report.json \
  || true

echo ""
echo "5. Capturing quick summaries..."

{
  echo "---- Trivy checkout summary ----"
  tail -n 40 "$OUT_DIR/trivy-checkout-fn.txt" || true

  echo ""
  echo "---- Checkov summary lines ----"
  grep -E "Passed checks|Failed checks|Check:" "$OUT_DIR/checkov-k8s-manifests.txt" | head -n 80 || true

  echo ""
  echo "---- ZAP warnings summary ----"
  if [ -f "$OUT_DIR/zap-baseline-warnings.md" ]; then
    head -n 80 "$OUT_DIR/zap-baseline-warnings.md"
  else
    echo "ZAP warnings file not created."
  fi
} | tee "$OUT_DIR/security-test-summary.txt"

echo ""
echo "======================================"
echo "Security testing completed."
echo "Evidence saved in $OUT_DIR"
echo "======================================"
