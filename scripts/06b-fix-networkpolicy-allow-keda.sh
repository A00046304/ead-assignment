#!/usr/bin/env bash
set -e

NAMESPACE="${NAMESPACE:-lab4}"
OUT_DIR="evidence/05-networkpolicies"

mkdir -p "$OUT_DIR"

echo "======================================"
echo "CA2 Fix: Allow KEDA interceptor to checkout"
echo "Namespace: $NAMESPACE"
echo "======================================"

NODE_IP="$(kubectl get node ead-server -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}')"

echo "Detected node IP: $NODE_IP"

echo ""
echo "1. Labelling keda namespace so NetworkPolicy can safely allow it..."
kubectl label namespace keda ca2-role=keda --overwrite

echo ""
echo "2. Replacing checkout NetworkPolicy with gateway + keda + node health allowed..."

cat > /tmp/checkout-ingress-from-gateway-fixed.yaml <<POLICY
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: checkout-ingress-from-gateway
  namespace: ${NAMESPACE}
spec:
  podSelector:
    matchLabels:
      app: checkout-fn
  policyTypes:
    - Ingress
  ingress:
    - from:
        - podSelector:
            matchLabels:
              app: gateway
        - namespaceSelector:
            matchLabels:
              ca2-role: keda
        - ipBlock:
            cidr: ${NODE_IP}/32
      ports:
        - protocol: TCP
          port: 3003
POLICY

kubectl apply -f /tmp/checkout-ingress-from-gateway-fixed.yaml

echo ""
echo "3. Capturing updated policies..."
kubectl get networkpolicy -n "$NAMESPACE" -o wide | tee "$OUT_DIR/networkpolicies-after-keda-fix.txt"
kubectl get networkpolicy checkout-ingress-from-gateway -n "$NAMESPACE" -o yaml | tee "$OUT_DIR/checkout-networkpolicy-keda-fixed.yaml.txt"

echo ""
echo "4. Testing normal checkout path again..."
curl -i --max-time 15 \
  -H "Content-Type: application/json" \
  -H "X-Request-Id: ca2-networkpolicy-keda-fix-001" \
  -d '{"sku":1,"subtotal":100}' \
  http://localhost/api/checkout | tee "$OUT_DIR/normal-checkout-after-keda-policy-fix.txt" || true

echo ""
echo "5. Re-testing blocked unauthorised pod to pricing..."
kubectl delete pod denied-client -n "$NAMESPACE" --ignore-not-found=true --grace-period=0 --force || true

kubectl run denied-client \
  -n "$NAMESPACE" \
  --image=nginx:1.27-alpine \
  --labels=app=denied-client \
  --restart=Never \
  --command -- sleep 3600

kubectl wait --for=condition=Ready pod/denied-client -n "$NAMESPACE" --timeout=120s

set +e
kubectl exec -n "$NAMESPACE" denied-client -- \
  wget -T 3 -qO- http://pricing-svc:3001/health \
  > "$OUT_DIR/blocked-client-to-pricing-after-keda-fix.txt" 2>&1
DENIED_STATUS=$?
set -e

echo "Blocked client exit code: $DENIED_STATUS" | tee -a "$OUT_DIR/blocked-client-to-pricing-after-keda-fix.txt"

if [ "$DENIED_STATUS" -eq 0 ]; then
  echo "WARNING: denied-client reached pricing. NetworkPolicy may not be enforced as expected." | tee -a "$OUT_DIR/blocked-client-to-pricing-after-keda-fix.txt"
else
  echo "Expected result: denied-client could not reach pricing-svc." | tee -a "$OUT_DIR/blocked-client-to-pricing-after-keda-fix.txt"
fi

echo ""
echo "6. Final pod state..."
kubectl get pods -n "$NAMESPACE" -o wide | tee "$OUT_DIR/pods-after-keda-networkpolicy-fix.txt"

echo ""
echo "======================================"
echo "NetworkPolicy KEDA fix completed."
echo "======================================"
