#!/usr/bin/env bash
set -e

NAMESPACE="${NAMESPACE:-lab4}"
OUT_DIR="evidence/03-workload-hardening"

mkdir -p "$OUT_DIR"

echo "======================================"
echo "CA2 Fix: Stabilise workload hardening"
echo "Namespace: $NAMESPACE"
echo "======================================"

echo ""
echo "1. Backing up current hardening manifest..."
cp k8s/manifests/10-functions.yaml "$OUT_DIR/10-functions.before-stability-fix.yaml"

echo ""
echo "2. Adjusting Node service securityContext..."
echo "Keeping: runAsNonRoot, allowPrivilegeEscalation false, drop capabilities, resource limits"
echo "Removing: readOnlyRootFilesystem true because existing Node images may need writable runtime paths"

python3 <<'PY'
from pathlib import Path
import re

path = Path("k8s/manifests/10-functions.yaml")
text = path.read_text()

# Remove readOnlyRootFilesystem if it exists
text = text.replace("            readOnlyRootFilesystem: true\n", "")

# Add explicit UID/GID under runAsNonRoot if not already present
text = text.replace(
    "            runAsNonRoot: true\n"
    "            allowPrivilegeEscalation: false\n",
    "            runAsNonRoot: true\n"
    "            runAsUser: 1000\n"
    "            runAsGroup: 1000\n"
    "            allowPrivilegeEscalation: false\n"
)

# Prevent duplicate runAsUser/runAsGroup if script is re-run
text = re.sub(r"(runAsNonRoot: true\n)(\s+runAsUser: 1000\n\s+runAsGroup: 1000\n)+", r"\1            runAsUser: 1000\n            runAsGroup: 1000\n", text)

path.write_text(text)
PY

echo ""
echo "3. Applying updated function manifest..."
kubectl apply -n "$NAMESPACE" -f k8s/manifests/10-functions.yaml

echo ""
echo "4. Restarting function deployments..."
kubectl rollout restart deployment/pricing-fn -n "$NAMESPACE"
kubectl rollout restart deployment/inventory-fn -n "$NAMESPACE"
kubectl rollout restart deployment/checkout-fn -n "$NAMESPACE"

echo ""
echo "5. Waiting for pricing and inventory rollouts..."
kubectl rollout status deployment/pricing-fn -n "$NAMESPACE" --timeout=180s
kubectl rollout status deployment/inventory-fn -n "$NAMESPACE" --timeout=180s

echo ""
echo "6. Checkout may be 0 replicas because of KEDA, so not forcing it as failure."
kubectl get deploy checkout-fn -n "$NAMESPACE" -o wide || true

echo ""
echo "7. Capturing evidence..."

{
  echo "---- Pods after stability fix ----"
  kubectl get pods -n "$NAMESPACE" -o wide

  echo ""
  echo "---- Function deployment hardening evidence ----"
  kubectl get deploy pricing-fn -n "$NAMESPACE" -o yaml | grep -A25 -B5 "securityContext" || true

  echo ""
  echo "---- ServiceAccount evidence ----"
  kubectl get deploy pricing-fn -n "$NAMESPACE" -o jsonpath='{.spec.template.spec.serviceAccountName}{"\n"}'
  kubectl get deploy inventory-fn -n "$NAMESPACE" -o jsonpath='{.spec.template.spec.serviceAccountName}{"\n"}'
  kubectl get deploy checkout-fn -n "$NAMESPACE" -o jsonpath='{.spec.template.spec.serviceAccountName}{"\n"}'

  echo ""
  echo "---- Token automount evidence ----"
  kubectl get deploy pricing-fn -n "$NAMESPACE" -o jsonpath='{.spec.template.spec.automountServiceAccountToken}{"\n"}'
  kubectl get deploy inventory-fn -n "$NAMESPACE" -o jsonpath='{.spec.template.spec.automountServiceAccountToken}{"\n"}'
  kubectl get deploy checkout-fn -n "$NAMESPACE" -o jsonpath='{.spec.template.spec.automountServiceAccountToken}{"\n"}'

} | tee "$OUT_DIR/workload-hardening-stability-fix-evidence.txt"

echo ""
echo "======================================"
echo "Hardening stability fix completed."
echo "======================================"
