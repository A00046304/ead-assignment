# CA2 Evidence Index

## 1. Baseline and Current State
- evidence/00-baseline/
- Shows original CA1 Kubernetes state before CA2 security and observability improvements.

## 2. Secrets Handling
- evidence/01-secrets/
- Shows removal of fallback database credentials and runtime Kubernetes Secret creation.

## 3. Workload Hardening
- evidence/03-workload-hardening/
- Shows ServiceAccounts, automountServiceAccountToken=false, securityContext, non-root execution and capability drop.

## 4. Observability
- evidence/04-observability/
- Shows normal metrics, timeout scenario, logs with request IDs, dependency timeout count and recovery.

## 5. NetworkPolicies
- evidence/05-networkpolicies/
- Shows targeted internal traffic restrictions and blocked unauthorised access to pricing-svc.

## 6. Security Testing
- evidence/06-security-testing/
- Contains Trivy image scan, Checkov Kubernetes posture scan and ZAP baseline gateway test.

## 7. Reboot and Recovery
- evidence/07-reboot-recovery/
- Shows practical recovery after VM reboot, disk-pressure handling, image re-import and gateway direct checkout fix.

## 8. Final State
- evidence/08-final-state/
- Final Kubernetes state, service accounts, endpoint tests and working checkout evidence.
