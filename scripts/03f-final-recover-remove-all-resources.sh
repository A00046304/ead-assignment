#!/usr/bin/env bash
set -e

NAMESPACE="${NAMESPACE:-lab4}"

echo "======================================"
echo "Final recovery: remove resource blocks"
echo "======================================"

echo ""
echo "1. Remove resource requests/limits from deployments directly..."

for deploy in pricing-fn inventory-fn gateway postgres checkout-fn; do
  echo "Patching $deploy..."
  kubectl patch deployment "$deploy" -n "$NAMESPACE" --type='json' \
    -p='[{"op":"replace","path":"/spec/template/spec/containers/0/resources","value":{}}]' || true
done

echo ""
echo "2. Scale services down..."
kubectl scale deployment pricing-fn -n "$NAMESPACE" --replicas=0 || true
kubectl scale deployment inventory-fn -n "$NAMESPACE" --replicas=0 || true
kubectl scale deployment gateway -n "$NAMESPACE" --replicas=0 || true
kubectl scale deployment postgres -n "$NAMESPACE" --replicas=0 || true
kubectl scale deployment checkout-fn -n "$NAMESPACE" --replicas=0 || true

sleep 10

echo ""
echo "3. Delete pending pods..."
kubectl delete pod -n "$NAMESPACE" -l app=pricing-fn --grace-period=0 --force --ignore-not-found || true
kubectl delete pod -n "$NAMESPACE" -l app=inventory-fn --grace-period=0 --force --ignore-not-found || true
kubectl delete pod -n "$NAMESPACE" -l app=gateway --grace-period=0 --force --ignore-not-found || true
kubectl delete pod -n "$NAMESPACE" -l app=postgres --grace-period=0 --force --ignore-not-found || true

echo ""
echo "4. Scale services back up..."
kubectl scale deployment postgres -n "$NAMESPACE" --replicas=1
kubectl scale deployment pricing-fn -n "$NAMESPACE" --replicas=1
kubectl scale deployment inventory-fn -n "$NAMESPACE" --replicas=1
kubectl scale deployment gateway -n "$NAMESPACE" --replicas=1

echo ""
echo "5. Keep checkout at zero because KEDA can scale it from zero..."
kubectl scale deployment checkout-fn -n "$NAMESPACE" --replicas=0 || true

echo ""
echo "6. Wait 30 seconds..."
sleep 30

echo ""
echo "7. Current state:"
kubectl get deploy,pods,svc,ingress -n "$NAMESPACE" -o wide

echo ""
echo "8. Check hardening evidence:"
for deploy in pricing-fn inventory-fn checkout-fn gateway postgres; do
  echo -n "$deploy serviceAccountName="
  kubectl get deploy "$deploy" -n "$NAMESPACE" -o jsonpath='{.spec.template.spec.serviceAccountName}{"\n"}' || true

  echo -n "$deploy automountServiceAccountToken="
  kubectl get deploy "$deploy" -n "$NAMESPACE" -o jsonpath='{.spec.template.spec.automountServiceAccountToken}{"\n"}' || true
done

echo ""
echo "======================================"
echo "Recovery complete"
echo "======================================"
