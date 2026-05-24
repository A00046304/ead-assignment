#!/usr/bin/env bash
set -e

NAMESPACE="${NAMESPACE:-lab4}"
OUT_DIR="evidence/03-workload-hardening"

mkdir -p "$OUT_DIR"

echo "======================================"
echo "CA2 Fix: Reset stuck rollouts safely"
echo "Namespace: $NAMESPACE"
echo "======================================"

echo ""
echo "1. Current state before reset..."
kubectl get deploy,rs,pods -n "$NAMESPACE" -o wide | tee "$OUT_DIR/before-reset-stuck-rollouts.txt"

echo ""
echo "2. Scaling non-database services down to clear stuck rollout pods..."

for deploy in pricing-fn inventory-fn gateway; do
  echo "Scaling $deploy to 0..."
  kubectl scale deployment "$deploy" -n "$NAMESPACE" --replicas=0
done

echo ""
echo "3. Waiting for old pods to terminate..."
sleep 10
kubectl get pods -n "$NAMESPACE" -o wide

echo ""
echo "4. Force deleting only stuck non-database pods if they remain..."
for app in pricing-fn inventory-fn gateway; do
  kubectl delete pod -n "$NAMESPACE" -l app="$app" --ignore-not-found=true --grace-period=0 --force || true
done

echo ""
echo "5. Scaling services back up..."
kubectl scale deployment pricing-fn -n "$NAMESPACE" --replicas=1
kubectl scale deployment inventory-fn -n "$NAMESPACE" --replicas=1
kubectl scale deployment gateway -n "$NAMESPACE" --replicas=1

echo ""
echo "6. Waiting for services to become ready..."
kubectl rollout status deployment/pricing-fn -n "$NAMESPACE" --timeout=180s
kubectl rollout status deployment/inventory-fn -n "$NAMESPACE" --timeout=180s
kubectl rollout status deployment/gateway -n "$NAMESPACE" --timeout=180s

echo ""
echo "7. Handling checkout-fn carefully because KEDA may keep it at zero..."
kubectl scale deployment checkout-fn -n "$NAMESPACE" --replicas=0 || true

echo ""
echo "8. Checking PostgreSQL. If it has a pending extra pod, keep the running pod and do not force-delete data."
kubectl get pods -n "$NAMESPACE" -l app=postgres -o wide || true

echo ""
echo "9. Final state after reset..."

{
  echo "---- Deployments, ReplicaSets and Pods ----"
  kubectl get deploy,rs,pods -n "$NAMESPACE" -o wide

  echo ""
  echo "---- Services and Ingress ----"
  kubectl get svc,ingress -n "$NAMESPACE" -o wide

  echo ""
  echo "---- ServiceAccount evidence ----"
  for deploy in pricing-fn inventory-fn checkout-fn gateway postgres; do
    echo -n "$deploy serviceAccountName="
    kubectl get deploy "$deploy" -n "$NAMESPACE" -o jsonpath='{.spec.template.spec.serviceAccountName}{"\n"}' || true
  done

  echo ""
  echo "---- Token automount evidence ----"
  for deploy in pricing-fn inventory-fn checkout-fn gateway postgres; do
    echo -n "$deploy automountServiceAccountToken="
    kubectl get deploy "$deploy" -n "$NAMESPACE" -o jsonpath='{.spec.template.spec.automountServiceAccountToken}{"\n"}' || true
  done

} | tee "$OUT_DIR/after-reset-stuck-rollouts.txt"

echo ""
echo "======================================"
echo "Stuck rollout reset completed."
echo "======================================"
