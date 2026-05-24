#!/usr/bin/env bash
set -e

NAMESPACE="${NAMESPACE:-lab4}"
OUT_DIR="evidence/03-workload-hardening"

mkdir -p "$OUT_DIR"

echo "======================================"
echo "CA2 Step 2: Workload hardening"
echo "Namespace: $NAMESPACE"
echo "======================================"

echo ""
echo "1. Backing up current manifests..."
cp k8s/manifests/10-functions.yaml "$OUT_DIR/10-functions.before-hardening.yaml"
cp k8s/manifests/20-gateway.yaml "$OUT_DIR/20-gateway.before-hardening.yaml"
cp k8s/manifests/70-postgres.yaml "$OUT_DIR/70-postgres.before-hardening.yaml"
cp k8s/manifests/90-toolbox.yaml "$OUT_DIR/90-toolbox.before-hardening.yaml"

echo ""
echo "2. Patching function workloads with ServiceAccounts, token disablement, securityContext and resources..."

python3 <<'PY'
from pathlib import Path
import re

path = Path("k8s/manifests/10-functions.yaml")
text = path.read_text()

service_accounts = {
    "pricing-fn": "pricing-sa",
    "inventory-fn": "inventory-sa",
    "checkout-fn": "checkout-sa",
}

for app, sa in service_accounts.items():
    # Add serviceAccountName and automountServiceAccountToken at pod spec level
    pattern = (
        rf"(    metadata:\n"
        rf"      labels:\n"
        rf"        app: {re.escape(app)}\n"
        rf"    spec:\n)"
    )
    replacement = (
        rf"\1"
        rf"      serviceAccountName: {sa}\n"
        rf"      automountServiceAccountToken: false\n"
    )

    if f"serviceAccountName: {sa}" not in text:
        text = re.sub(pattern, replacement, text)

    # Add pod-level seccomp profile
    pod_seccomp_marker = f"serviceAccountName: {sa}\n      automountServiceAccountToken: false\n      securityContext:"
    if pod_seccomp_marker not in text:
        text = text.replace(
            f"serviceAccountName: {sa}\n      automountServiceAccountToken: false\n      containers:",
            f"serviceAccountName: {sa}\n      automountServiceAccountToken: false\n"
            f"      securityContext:\n"
            f"        seccompProfile:\n"
            f"          type: RuntimeDefault\n"
            f"      containers:"
        )

    # Add container securityContext and resources
    container_pattern = (
        rf"(        - name: {re.escape(app)}\n"
        rf"          image: [^\n]+\n"
        rf"          imagePullPolicy: Never\n)"
    )

    hardening_block = (
        r"\1"
        "          securityContext:\n"
        "            runAsNonRoot: true\n"
        "            allowPrivilegeEscalation: false\n"
        "            readOnlyRootFilesystem: true\n"
        "            capabilities:\n"
        "              drop:\n"
        "                - ALL\n"
        "          resources:\n"
        "            requests:\n"
        "              cpu: 50m\n"
        "              memory: 64Mi\n"
        "            limits:\n"
        "              cpu: 250m\n"
        "              memory: 128Mi\n"
    )

    # Only patch if this container does not already have securityContext nearby
    if re.search(container_pattern, text) and f"- name: {app}\n          image:" in text:
        block_start = text.find(f"- name: {app}")
        block_end = text.find("---", block_start)
        if block_end == -1:
            block_end = len(text)
        block = text[block_start:block_end]
        if "allowPrivilegeEscalation: false" not in block:
            text = re.sub(container_pattern, hardening_block, text)

path.write_text(text)
PY

echo ""
echo "3. Patching gateway deployment with dedicated ServiceAccount and resource limits..."

python3 <<'PY'
from pathlib import Path
import re

path = Path("k8s/manifests/20-gateway.yaml")
text = path.read_text()

if "serviceAccountName: gateway-sa" not in text:
    text = text.replace(
        "    spec:\n      containers:",
        "    spec:\n      serviceAccountName: gateway-sa\n      automountServiceAccountToken: false\n      containers:"
    )

if "cpu: 50m" not in text:
    text = text.replace(
        "          ports:\n            - containerPort: 80\n",
        "          ports:\n            - containerPort: 80\n"
        "          resources:\n"
        "            requests:\n"
        "              cpu: 50m\n"
        "              memory: 64Mi\n"
        "            limits:\n"
        "              cpu: 250m\n"
        "              memory: 128Mi\n"
    )

path.write_text(text)
PY

echo ""
echo "4. Patching PostgreSQL deployment with dedicated ServiceAccount and resource limits..."

python3 <<'PY'
from pathlib import Path

path = Path("k8s/manifests/70-postgres.yaml")
text = path.read_text()

if "serviceAccountName: postgres-sa" not in text:
    text = text.replace(
        "    spec:\n      containers:",
        "    spec:\n      serviceAccountName: postgres-sa\n      automountServiceAccountToken: false\n      containers:"
    )

if "cpu: 100m" not in text:
    text = text.replace(
        "          ports:\n            - containerPort: 5432\n",
        "          ports:\n            - containerPort: 5432\n"
        "          resources:\n"
        "            requests:\n"
        "              cpu: 100m\n"
        "              memory: 128Mi\n"
        "            limits:\n"
        "              cpu: 500m\n"
        "              memory: 512Mi\n"
    )

path.write_text(text)
PY

echo ""
echo "5. Patching toolbox pod with dedicated ServiceAccount..."

python3 <<'PY'
from pathlib import Path

path = Path("k8s/manifests/90-toolbox.yaml")
text = path.read_text()

if "serviceAccountName: toolbox-sa" not in text:
    text = text.replace(
        "spec:\n  containers:",
        "spec:\n  serviceAccountName: toolbox-sa\n  automountServiceAccountToken: false\n  containers:"
    )

path.write_text(text)
PY

echo ""
echo "6. Applying hardened manifests..."

kubectl apply -n "$NAMESPACE" -f k8s/manifests/21-serviceaccounts.yaml
kubectl apply -n "$NAMESPACE" -f k8s/manifests/10-functions.yaml
kubectl apply -n "$NAMESPACE" -f k8s/manifests/20-gateway.yaml
kubectl apply -n "$NAMESPACE" -f k8s/manifests/70-postgres.yaml

echo ""
echo "7. Recreating toolbox pod because Pod specs are mostly immutable..."
kubectl delete pod toolbox -n "$NAMESPACE" --ignore-not-found=true
kubectl apply -n "$NAMESPACE" -f k8s/manifests/90-toolbox.yaml

echo ""
echo "8. Waiting for rollout..."
kubectl rollout status deployment/pricing-fn -n "$NAMESPACE" --timeout=120s
kubectl rollout status deployment/inventory-fn -n "$NAMESPACE" --timeout=120s
kubectl rollout status deployment/checkout-fn -n "$NAMESPACE" --timeout=120s || true
kubectl rollout status deployment/gateway -n "$NAMESPACE" --timeout=120s
kubectl rollout status deployment/postgres -n "$NAMESPACE" --timeout=120s

echo ""
echo "9. Capturing evidence..."

{
  echo "---- ServiceAccounts ----"
  kubectl get sa -n "$NAMESPACE"

  echo ""
  echo "---- Resources after hardening ----"
  kubectl get deploy,pods,svc,ingress -n "$NAMESPACE" -o wide

  echo ""
  echo "---- Deployment ServiceAccount evidence ----"
  kubectl get deploy pricing-fn -n "$NAMESPACE" -o jsonpath='{.spec.template.spec.serviceAccountName}{"\n"}'
  kubectl get deploy inventory-fn -n "$NAMESPACE" -o jsonpath='{.spec.template.spec.serviceAccountName}{"\n"}'
  kubectl get deploy checkout-fn -n "$NAMESPACE" -o jsonpath='{.spec.template.spec.serviceAccountName}{"\n"}'
  kubectl get deploy gateway -n "$NAMESPACE" -o jsonpath='{.spec.template.spec.serviceAccountName}{"\n"}'
  kubectl get deploy postgres -n "$NAMESPACE" -o jsonpath='{.spec.template.spec.serviceAccountName}{"\n"}'

  echo ""
  echo "---- Token automount evidence ----"
  kubectl get deploy checkout-fn -n "$NAMESPACE" -o jsonpath='{.spec.template.spec.automountServiceAccountToken}{"\n"}'
  kubectl get deploy pricing-fn -n "$NAMESPACE" -o jsonpath='{.spec.template.spec.automountServiceAccountToken}{"\n"}'
  kubectl get deploy inventory-fn -n "$NAMESPACE" -o jsonpath='{.spec.template.spec.automountServiceAccountToken}{"\n"}'
  kubectl get deploy gateway -n "$NAMESPACE" -o jsonpath='{.spec.template.spec.automountServiceAccountToken}{"\n"}'

  echo ""
  echo "---- SecurityContext evidence from checkout ----"
  kubectl get deploy checkout-fn -n "$NAMESPACE" -o yaml | grep -A20 -B5 "securityContext" || true

  echo ""
  echo "---- Resource limit evidence from checkout ----"
  kubectl get deploy checkout-fn -n "$NAMESPACE" -o yaml | grep -A12 -B3 "resources:" || true

} | tee "$OUT_DIR/workload-hardening-evidence.txt"

echo ""
echo "======================================"
echo "Workload hardening completed."
echo "Evidence saved in $OUT_DIR"
echo "======================================"
