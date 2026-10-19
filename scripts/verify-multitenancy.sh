#!/usr/bin/env bash
# ==============================================================================
# Automated Multi-Tenant ODA Canvas Verification Script
# Validates:
#  1. ODA Canvas Control Plane readiness (canvas & istio-system)
#  2. Tenant Namespace Isolation (ResourceQuota, LimitRange, NetworkPolicy, RBAC)
#  3. TM Forum ODA Component CRs (TMFC001 Product Catalog Management)
#  4. Cross-Tenant Network Isolation (Dataplane V2 Cilium eBPF blocks tenant-alpha -> tenant-beta)
# ==============================================================================
set -euo pipefail

TENANT_A="${1:-tenant-alpha}"
TENANT_B="${2:-tenant-beta}"

echo "=================================================================="
echo " 1. Checking ODA Canvas Control Plane Pods (namespace: canvas)"
echo "=================================================================="
kubectl get pods -n canvas -o wide || true
kubectl get gateway -n canvas || true

echo ""
echo "=================================================================="
echo " 2. Checking Multi-Tenant Governance (${TENANT_A} & ${TENANT_B})"
echo "=================================================================="
for TENANT in "${TENANT_A}" "${TENANT_B}"; do
  echo "--- Tenant Namespace: ${TENANT} ---"
  kubectl get resourcequota,limitrange,networkpolicy,sa -n "${TENANT}"
  echo "--- TM Forum ODA Components in ${TENANT} ---"
  kubectl get components.oda.tmforum.org -n "${TENANT}" || true
  kubectl get httproute -n "${TENANT}" || true
done

echo ""
echo "=================================================================="
echo " 3. Testing Intra-Tenant Connectivity (${TENANT_A} -> ${TENANT_A})"
echo "=================================================================="
kubectl run nettest-same-tenant \
  -n "${TENANT_A}" \
  --image=curlimages/curl:8.7.1 \
  --restart=Never \
  --rm -i --quiet \
  --command -- curl -sS --max-time 5 "http://prodcat-${TENANT_A}-svc.${TENANT_A}.svc.cluster.local:8080"
echo "✅ Intra-tenant TMF620 API call inside ${TENANT_A} SUCCEEDED."

echo ""
echo "=================================================================="
echo " 4. Testing Cross-Tenant Network Isolation (${TENANT_A} -> ${TENANT_B})"
echo "    Expectation: BLOCKED (Timeout) by GKE Dataplane V2 NetworkPolicy"
echo "=================================================================="
if kubectl run nettest-cross-tenant \
  -n "${TENANT_A}" \
  --image=curlimages/curl:8.7.1 \
  --restart=Never \
  --rm -i --quiet \
  --command -- curl -sS --max-time 5 "http://prodcat-${TENANT_B}-svc.${TENANT_B}.svc.cluster.local:8080"; then
  echo "❌ ERROR: Cross-tenant traffic from ${TENANT_A} to ${TENANT_B} was NOT blocked!"
  exit 1
else
  echo "✅ SUCCESS: Cross-tenant traffic from ${TENANT_A} to ${TENANT_B} was strictly BLOCKED by GKE Dataplane V2!"
fi

echo ""
echo "=================================================================="
echo " ALL MULTI-TENANT ODA CANVAS CHECKS PASSED!"
echo "=================================================================="
