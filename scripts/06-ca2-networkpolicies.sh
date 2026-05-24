#!/usr/bin/env bash
set -e

NAMESPACE="${NAMESPACE:-lab4}"
OUT_DIR="evidence/05-networkpolicies"

mkdir -p "$OUT_DIR"

echo "======================================"
echo "CA2 Step 7: Targeted NetworkPolicies"
echo "Namespace: $NAMESPACE"
echo "======================================"

NODE_IP="$(kubectl get node ead-server -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}')"

if [ -z "$NODE_IP" ]; then
  echo "Could not detect node IP."
  exit 1
fi

echo "Detected node IP: $NODE_IP"

echo ""
echo "1. Capturing network policies before change..."
kubectl get networkpolicy -n "$NAMESPACE" -o wide | tee "$OUT_DIR/networkpolicies-before.txt" || true

echo ""
echo "2. Creating targeted NetworkPolicy manifest..."

cat > k8s/manifests/30-networkpolicies.yaml <<POLICY
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: checkout-ingress-from-gateway
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
        - ipBlock:
            cidr: ${NODE_IP}/32
      ports:
        - protocol: TCP
          port: 3003
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: pricing-ingress-from-checkout
spec:
  podSelector:
    matchLabels:
      app: pricing-fn
  policyTypes:
    - Ingress
  ingress:
    - from:
        - podSelector:
            matchLabels:
              app: checkout-fn
        - ipBlock:
            cidr: ${NODE_IP}/32
      ports:
        - protocol: TCP
          port: 3001
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: inventory-ingress-from-checkout
spec:
  podSelector:
    matchLabels:
      app: inventory-fn
  policyTypes:
    - Ingress
  ingress:
    - from:
        - podSelector:
            matchLabels:
              app: checkout-fn
        - ipBlock:
            cidr: ${NODE_IP}/32
      ports:
        - protocol: TCP
          port: 3002
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: postgres-ingress-from-checkout
spec:
  podSelector:
    matchLabels:
      app: postgres
  policyTypes:
    - Ingress
  ingress:
    - from:
        - podSelector:
            matchLabels:
              app: checkout-fn
        - podSelector:
            matchLabels:
              app: toolbox
      ports:
        - protocol: TCP
          port: 5432
POLICY

cat k8s/manifests/30-networkpolicies.yaml | tee "$OUT_DIR/30-networkpolicies.yaml.txt"

echo ""
echo "3. Applying NetworkPolicies..."
kubectl apply -n "$NAMESPACE" -f k8s/manifests/30-networkpolicies.yaml

echo ""
echo "4. Waiting briefly..."
sleep 5

echo ""
echo "5. Capturing policies after apply..."
kubectl get networkpolicy -n "$NAMESPACE" -o wide | tee "$OUT_DIR/networkpolicies-after.txt"

echo ""
echo "6. Testing normal public checkout path still works..."
curl -i --max-time 10 \
  -H "Content-Type: application/json" \
  -H "X-Request-Id: ca2-networkpolicy-normal-001" \
  -d '{"sku":1,"subtotal":100}' \
  http://localhost/api/checkout | tee "$OUT_DIR/normal-checkout-after-networkpolicy.txt" || true

echo ""
echo "7. Testing blocked access from an unauthorised pod to pricing service..."
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
  > "$OUT_DIR/blocked-client-to-pricing.txt" 2>&1
DENIED_STATUS=$?
set -e

echo "Blocked client exit code: $DENIED_STATUS" | tee -a "$OUT_DIR/blocked-client-to-pricing.txt"

if [ "$DENIED_STATUS" -eq 0 ]; then
  echo "WARNING: denied-client reached pricing. NetworkPolicy may not be enforced by this K3s/CNI setup." | tee -a "$OUT_DIR/blocked-client-to-pricing.txt"
else
  echo "Expected result: denied-client could not reach pricing-svc." | tee -a "$OUT_DIR/blocked-client-to-pricing.txt"
fi

echo ""
echo "8. Testing allowed route through checkout still works after blocked test..."
curl -i --max-time 10 \
  -H "Content-Type: application/json" \
  -H "X-Request-Id: ca2-networkpolicy-allowed-001" \
  -d '{"sku":1,"subtotal":100}' \
  http://localhost/api/checkout | tee "$OUT_DIR/allowed-checkout-after-blocked-test.txt" || true

echo ""
echo "9. Final pod state..."
kubectl get pods -n "$NAMESPACE" -o wide | tee "$OUT_DIR/pods-after-networkpolicy.txt"

echo ""
echo "======================================"
echo "NetworkPolicy implementation completed."
echo "Evidence saved in $OUT_DIR"
echo "======================================"
