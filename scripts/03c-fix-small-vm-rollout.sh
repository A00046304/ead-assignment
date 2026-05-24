#!/usr/bin/env bash
set -e

NAMESPACE="${NAMESPACE:-lab4}"
OUT_DIR="evidence/03-workload-hardening"

mkdir -p "$OUT_DIR"

echo "======================================"
echo "CA2 Fix: Small VM rollout/resource fix"
echo "Namespace: $NAMESPACE"
echo "======================================"

echo ""
echo "1. Backing up manifests..."
cp k8s/manifests/10-functions.yaml "$OUT_DIR/10-functions.before-small-vm-fix.yaml"
cp k8s/manifests/20-gateway.yaml "$OUT_DIR/20-gateway.before-small-vm-fix.yaml"
cp k8s/manifests/70-postgres.yaml "$OUT_DIR/70-postgres.before-small-vm-fix.yaml"

echo ""
echo "2. Reducing resource requests for VirtualBox single-node lab..."

python3 <<'PY'
from pathlib import Path

for file in ["k8s/manifests/10-functions.yaml", "k8s/manifests/20-gateway.yaml", "k8s/manifests/70-postgres.yaml"]:
    p = Path(file)
    text = p.read_text()

    text = text.replace("cpu: 50m", "cpu: 10m")
    text = text.replace("memory: 64Mi", "memory: 32Mi")
    text = text.replace("cpu: 100m", "cpu: 20m")
    text = text.replace("memory: 128Mi", "memory: 64Mi")

    # keep limits, but make them smaller for lab VM
    text = text.replace("cpu: 250m", "cpu: 150m")
    text = text.replace("memory: 128Mi", "memory: 96Mi")
    text = text.replace("cpu: 500m", "cpu: 250m")
    text = text.replace("memory: 512Mi", "memory: 256Mi")

    p.write_text(text)
PY

echo ""
echo "3. Setting pricing-fn replicas to 1 for lab resource control..."

python3 <<'PY'
from pathlib import Path
import re

p = Path("k8s/manifests/10-functions.yaml")
text = p.read_text()

# In the pricing-fn deployment only, set replicas to 1
pattern = r"(kind: Deployment\nmetadata:\n  name: pricing-fn\n[\s\S]*?spec:\n  replicas: )\d+"
text = re.sub(pattern, r"\g<1>1", text, count=1)

p.write_text(text)
PY

echo ""
echo "4. Applying manifests..."
kubectl apply -n "$NAMESPACE" -f k8s/manifests/10-functions.yaml
kubectl apply -n "$NAMESPACE" -f k8s/manifests/20-gateway.yaml
kubectl apply -n "$NAMESPACE" -f k8s/manifests/70-postgres.yaml

echo ""
echo "5. Patching deployment rollout strategy to avoid surge pods..."
for deploy in pricing-fn inventory-fn checkout-fn gateway postgres; do
  kubectl patch deployment "$deploy" -n "$NAMESPACE" --type='merge' -p \
  '{"spec":{"strategy":{"type":"RollingUpdate","rollingUpdate":{"maxSurge":0,"maxUnavailable":1}}}}' || true
done

echo ""
echo "6. Cleaning stuck rollout by restarting deployments one by one..."

for deploy in pricing-fn inventory-fn gateway postgres; do
  echo ""
  echo "Restarting $deploy..."
  kubectl rollout restart deployment/"$deploy" -n "$NAMESPACE"
  kubectl rollout status deployment/"$deploy" -n "$NAMESPACE" --timeout=180s
done

echo ""
echo "7. Checkout may stay at 0 because of KEDA. Restarting but not forcing rollout as failure..."
kubectl rollout restart deployment/checkout-fn -n "$NAMESPACE" || true

echo ""
echo "8. Capturing evidence..."

{
  echo "---- Node allocated resources ----"
  kubectl describe node ead-server | sed -n '/Allocated resources:/,/Events:/p'

  echo ""
  echo "---- Deployments and pods ----"
  kubectl get deploy,pods,svc,ingress -n "$NAMESPACE" -o wide

  echo ""
  echo "---- ServiceAccount evidence ----"
  for deploy in pricing-fn inventory-fn checkout-fn gateway postgres; do
    echo -n "$deploy serviceAccountName="
    kubectl get deploy "$deploy" -n "$NAMESPACE" -o jsonpath='{.spec.template.spec.serviceAccountName}{"\n"}'
  done

  echo ""
  echo "---- Token automount evidence ----"
  for deploy in pricing-fn inventory-fn checkout-fn gateway postgres; do
    echo -n "$deploy automountServiceAccountToken="
    kubectl get deploy "$deploy" -n "$NAMESPACE" -o jsonpath='{.spec.template.spec.automountServiceAccountToken}{"\n"}'
  done

  echo ""
  echo "---- Pricing resources evidence ----"
  kubectl get deploy pricing-fn -n "$NAMESPACE" -o yaml | grep -A15 -B3 "resources:" || true

} | tee "$OUT_DIR/small-vm-rollout-fix-evidence.txt"

echo ""
echo "======================================"
echo "Small VM rollout/resource fix completed."
echo "======================================"
