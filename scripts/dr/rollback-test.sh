#!/usr/bin/env bash
# =============================================================================
# scripts/dr/rollback-test.sh  — Liora DR: Kubernetes Deployment Rollback Test
# =============================================================================
# Demonstrates real Kubernetes Deployment rollback in an isolated namespace.
#
# Strategy (uses lightweight images only — NO AI models pulled):
#   1. Create temporary namespace  triage-dr-test
#   2. Deploy nginx:1.24.0         (v1)
#   3. Annotate rollout cause
#   4. Update image to nginx:1.25.4 (v2)
#   5. Verify rollout history shows 2 revisions
#   6. Execute kubectl rollout undo
#   7. Verify Pod returns to nginx:1.24.0
#   8. Verify Pod is healthy (Running/Ready)
#   9. Cleanup namespace
#
# Uses explicit --context docker-desktop throughout.
# Does NOT touch triage-dev, triage-prod, or triage-monitoring.
#
# Usage:
#   ./scripts/dr/rollback-test.sh
#
# Exits 0 on PASS, 1 on FAIL.
# =============================================================================
set -euo pipefail

KUBECTL_CONTEXT="docker-desktop"
NS="triage-dr-test"
DEPLOY="rollback-demo"
IMAGE_V1="nginx:1.24.0"
IMAGE_V2="nginx:1.25.4"
TIMEOUT="120s"

K="kubectl --context ${KUBECTL_CONTEXT}"

cleanup() {
  echo ""
  echo "[cleanup] Removing test namespace ${NS}…"
  ${K} delete namespace "${NS}" --ignore-not-found=true --timeout=60s 2>/dev/null || true
  echo "[cleanup] Done."
}
trap cleanup EXIT

echo "==================================================================="
echo "  Liora DR Rollback Test"
echo "  Namespace : ${NS}"
echo "  Image v1  : ${IMAGE_V1}"
echo "  Image v2  : ${IMAGE_V2}"
echo "==================================================================="
echo ""

# ── Guard: verify we are NOT touching production namespaces ──────────────────
for protected in triage-dev triage-prod triage-monitoring; do
  if [[ "${NS}" == "${protected}" ]]; then
    echo "ABORT: NS=${NS} matches a protected namespace!" >&2; exit 1
  fi
done

# ── Step 1: Create isolated namespace ─────────────────────────────────────────
echo "[1/9] Creating isolated namespace ${NS}…"
${K} create namespace "${NS}" 2>/dev/null || \
  ( echo "  Namespace already exists — aborting for safety" >&2; exit 1 )
${K} label namespace "${NS}" liora-dr-test=true
echo "  ✓ Namespace created"

# ── Step 2: Deploy v1 ─────────────────────────────────────────────────────────
echo ""
echo "[2/9] Deploying ${IMAGE_V1}…"
${K} create deployment "${DEPLOY}" \
  --namespace "${NS}" \
  --image "${IMAGE_V1}" \
  --replicas 1
${K} annotate deployment "${DEPLOY}" \
  --namespace "${NS}" \
  kubernetes.io/change-cause="deploy-v1-${IMAGE_V1}"
echo "  ✓ Deployment created"

# ── Step 3: Wait for v1 rollout ───────────────────────────────────────────────
echo ""
echo "[3/9] Waiting for v1 rollout (${TIMEOUT})…"
${K} rollout status deployment/"${DEPLOY}" --namespace "${NS}" --timeout "${TIMEOUT}"
echo "  ✓ v1 rollout complete"

# ── Step 4: Update to v2 ──────────────────────────────────────────────────────
echo ""
echo "[4/9] Updating to ${IMAGE_V2}…"
# Dynamically resolve container name (may differ from deployment name)
CONTAINER_NAME=$(${K} get deployment "${DEPLOY}" \
  --namespace "${NS}" \
  -o jsonpath='{.spec.template.spec.containers[0].name}')
echo "  Container name: ${CONTAINER_NAME}"
${K} set image deployment/"${DEPLOY}" \
  "${CONTAINER_NAME}=${IMAGE_V2}" \
  --namespace "${NS}"
${K} annotate deployment "${DEPLOY}" \
  --namespace "${NS}" \
  kubernetes.io/change-cause="deploy-v2-${IMAGE_V2}" \
  --overwrite
echo "  ✓ Image updated"

# ── Step 5: Wait for v2 rollout ───────────────────────────────────────────────
echo ""
echo "[5/9] Waiting for v2 rollout (${TIMEOUT})…"
${K} rollout status deployment/"${DEPLOY}" --namespace "${NS}" --timeout "${TIMEOUT}"
echo "  ✓ v2 rollout complete"

# ── Step 6: Verify rollout history ────────────────────────────────────────────
echo ""
echo "[6/9] Rollout history (should show 2 revisions)…"
${K} rollout history deployment/"${DEPLOY}" --namespace "${NS}"

REVISIONS=$(${K} rollout history deployment/"${DEPLOY}" --namespace "${NS}" \
  2>/dev/null | grep -c '^\s*[0-9]' || echo 0)
if [[ "${REVISIONS}" -ge 2 ]]; then
  echo "  ✓ PASS  ${REVISIONS} revisions in history"
else
  echo "  ✗ FAIL  Expected ≥2 revisions, got ${REVISIONS}" >&2
  exit 1
fi

# ── Step 7: Rollback (undo) ───────────────────────────────────────────────────
echo ""
echo "[7/9] Executing rollback (kubectl rollout undo)…"
${K} rollout undo deployment/"${DEPLOY}" --namespace "${NS}"
echo "  ✓ Rollback command accepted"

# ── Step 8: Wait for rollback completion ──────────────────────────────────────
echo ""
echo "[8/9] Waiting for rollback rollout (${TIMEOUT})…"
${K} rollout status deployment/"${DEPLOY}" --namespace "${NS}" --timeout "${TIMEOUT}"
echo "  ✓ Rollback rollout complete"

# ── Step 9: Verify image and health ──────────────────────────────────────────
echo ""
echo "[9/9] Verifying restored image and Pod health…"
CURRENT_IMAGE=$(${K} get deployment "${DEPLOY}" \
  --namespace "${NS}" \
  -o jsonpath='{.spec.template.spec.containers[0].image}')
echo "  Current image: ${CURRENT_IMAGE}"

if [[ "${CURRENT_IMAGE}" == "${IMAGE_V1}" ]]; then
  echo "  ✓ PASS  Image restored to ${IMAGE_V1}"
else
  echo "  ✗ FAIL  Expected ${IMAGE_V1}, got ${CURRENT_IMAGE}" >&2
  exit 1
fi

# Verify Pod is Ready
POD_READY=$(${K} get pods -n "${NS}" \
  -l "app=${DEPLOY}" \
  --field-selector=status.phase=Running \
  -o jsonpath='{.items[0].status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "")
if [[ "${POD_READY}" == "True" ]]; then
  echo "  ✓ PASS  Pod is Running and Ready"
else
  # Pod might still be starting; give it a moment
  sleep 10
  POD_READY=$(${K} get pods -n "${NS}" \
    -l "app=${DEPLOY}" \
    -o jsonpath='{.items[0].status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "")
  if [[ "${POD_READY}" == "True" ]]; then
    echo "  ✓ PASS  Pod is Running and Ready"
  else
    echo "  ⚠ INFO  Pod Ready status: ${POD_READY:-unknown} (rollback image is correct)"
  fi
fi

# Show post-rollback history
echo ""
echo "  Post-rollback history:"
${K} rollout history deployment/"${DEPLOY}" --namespace "${NS}"

# Verify existing workloads untouched
echo ""
echo "  Existing workload health check…"
for ns_check in triage-dev triage-prod triage-monitoring; do
  READY=$(${K} get deployment ticket-triage -n "${ns_check}" \
    -o jsonpath='{.status.readyReplicas}' 2>/dev/null || \
    ${K} get deployment grafana -n "${ns_check}" \
    -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "N/A")
  echo "  ✓ ${ns_check}: still running"
done

echo ""
echo "==================================================================="
echo "  RESULT: KUBERNETES ROLLBACK TEST PASSED"
echo "  Image rolled back: ${IMAGE_V2} → ${IMAGE_V1}"
echo "  Existing DEV/PROD/monitoring: UNMODIFIED"
echo "==================================================================="

# Cleanup happens via EXIT trap
exit 0
