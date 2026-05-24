#!/usr/bin/env bash
set -e

NAMESPACE="${NAMESPACE:-lab4}"
OUT_DIR="evidence/09-resource-governance"

mkdir -p "$OUT_DIR"

echo "======================================"
echo "CA2 Step 9: Resource governance"
echo "Namespace: $NAMESPACE"
echo "======================================"

echo ""
echo "1. Capturing node resources before governance..."
kubectl describe node ead-server | sed -n '/Allocated resources:/,/Events:/p' \
  | tee "$OUT_DIR/node-resources-before.txt"

echo ""
echo "2. Adding conservative requests and limits..."

kubectl set resources deployment/gateway -n "$NAMESPACE" \
  --requests=cpu=25m,memory=64Mi \
  --limits=cpu=200m,memory=128Mi

kubectl set resources deployment/checkout-fn -n "$NAMESPACE" \
  --requests=cpu=50m,memory=96Mi \
  --limits=cpu=300m,memory=256Mi

kubectl set resources deployment/pricing-fn -n "$NAMESPACE" \
  --requests=cpu=25m,memory=64Mi \
  --limits=cpu=200m,memory=128Mi

kubectl set resources deployment/inventory-fn -n "$NAMESPACE" \
  --requests=cpu=25m,memory=64Mi \
  --limits=cpu=200m,memory=128Mi

kubectl set resources deployment/postgres -n "$NAMESPACE" \
  --requests=cpu=100m,memory=256Mi \
  --limits=cpu=500m,memory=512Mi

echo ""
echo "3. Applying namespace ResourceQuota and LimitRange..."

cat > k8s/manifests/35-resource-governance.yaml <<'YAML'
apiVersion: v1
kind: ResourceQuota
metadata:
  name: lab4-resource-quota
spec:
  hard:
    requests.cpu: "1"
    requests.memory: 1Gi
    limits.cpu: "2"
    limits.memory: 2Gi
    pods: "15"
---
apiVersion: v1
kind: LimitRange
metadata:
  name: lab4-default-container-limits
spec:
  limits:
    - type: Container
      default:
        cpu: 200m
        memory: 256Mi
      defaultRequest:
        cpu: 25m
        memory: 64Mi
YAML

kubectl apply -n "$NAMESPACE" -f k8s/manifests/35-resource-governance.yaml

echo ""
echo "4. Restarting workloads to apply resource settings..."
kubectl rollout restart deployment/gateway deployment/checkout-fn deployment/pricing-fn deployment/inventory-fn deployment/postgres -n "$NAMESPACE"

echo ""
echo "5. Waiting for rollouts..."
kubectl rollout status deployment/postgres -n "$NAMESPACE" --timeout=180s
kubectl rollout status deployment/pricing-fn -n "$NAMESPACE" --timeout=180s
kubectl rollout status deployment/inventory-fn -n "$NAMESPACE" --timeout=180s
kubectl rollout status deployment/checkout-fn -n "$NAMESPACE" --timeout=180s
kubectl rollout status deployment/gateway -n "$NAMESPACE" --timeout=180s

echo ""
echo "6. Capturing evidence..."

{
  echo "---- ResourceQuota ----"
  kubectl get resourcequota -n "$NAMESPACE" -o wide

  echo ""
  echo "---- LimitRange ----"
  kubectl get limitrange -n "$NAMESPACE" -o yaml

  echo ""
  echo "---- Deployment resource settings ----"
  for deploy in gateway checkout-fn pricing-fn inventory-fn postgres; do
    echo "---- $deploy ----"
    kubectl get deploy "$deploy" -n "$NAMESPACE" -o yaml | grep -A12 -B3 "resources:" || true
  done

  echo ""
  echo "---- Node resources after governance ----"
  kubectl describe node ead-server | sed -n '/Allocated resources:/,/Events:/p'

  echo ""
  echo "---- Final pods ----"
  kubectl get pods -n "$NAMESPACE" -o wide

} | tee "$OUT_DIR/resource-governance-evidence.txt"

echo ""
echo "======================================"
echo "Resource governance completed."
echo "======================================"
