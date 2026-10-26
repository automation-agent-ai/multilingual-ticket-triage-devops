#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────────────────────
# ssm-remote-kustomize-deploy-prod.sh
#
# Executed on the EC2 host via SSM (stdin heredoc).
# Image and paths come from environment variables set by the caller.
#
# PROD-ONLY: enforces triage-prod namespace and aws-prod overlay.
# Mirror of ssm-remote-kustomize-deploy.sh with PROD-specific guards.
#
# Required environment variables (set by SSM caller):
#   DEPLOY_IMAGE      ghcr.io/…:aws-sha-<40-hex>
#   DEPLOY_NAMESPACE  triage-prod  (enforced — any other value aborts)
#   DEPLOY_OVERLAY    /home/ubuntu/…/k8s/overlays/aws-prod  (enforced)
#
# Rollback strategy:
#   1. kustomization.yaml is backed up before mutation.
#   2. On apply failure: backup is restored (deployment unchanged).
#   3. On rollout failure: previous kustomization is re-applied via kubectl apply.
#      kubectl rollout undo is used only as a secondary fallback (PROD may have
#      only one revision, making rollout undo insufficient on its own).
#   4. Rollback is verified: deployment image must match PREV_IMAGE after rollback.
#
# Test hook:
#   SSM_DEPLOY_TEST_HOOK=1
#   SSM_DEPLOY_APPROVED_OVERLAY_OVERRIDE=<path>
#   PREV_IMAGE / NEW_IMAGE / MOCK_SCENARIO (set by test harness)
# ──────────────────────────────────────────────────────────────────────────────
set -euo pipefail

# ── Overlay guard ─────────────────────────────────────────────────────────────
if [[ "${SSM_DEPLOY_TEST_HOOK:-}" == "1" && -n "${SSM_DEPLOY_APPROVED_OVERLAY_OVERRIDE:-}" ]]; then
  readonly APPROVED_OVERLAY="${SSM_DEPLOY_APPROVED_OVERLAY_OVERRIDE}"
else
  readonly APPROVED_OVERLAY="/home/ubuntu/workspaces/multilingual-ticket-triage-devops/k8s/overlays/aws-prod"
fi

IMAGE="${DEPLOY_IMAGE:?DEPLOY_IMAGE must be set}"
NAMESPACE="${DEPLOY_NAMESPACE:?DEPLOY_NAMESPACE must be set}"
OVERLAY="${DEPLOY_OVERLAY:?DEPLOY_OVERLAY must be set}"

PREV_IMAGE=""
KUSTOMIZATION_MUTATED=false
DEPLOYMENT_MUTATED=false
ROLLBACK_IN_PROGRESS=false

# ── Input validation ──────────────────────────────────────────────────────────

if [[ ! "$IMAGE" =~ ^ghcr\.io/automation-agent-ai/multilingual-ticket-triage-devops:aws-sha-[0-9a-f]{40}$ ]]; then
  echo "Invalid DEPLOY_IMAGE format — refusing PROD deploy: ${IMAGE}" >&2
  exit 1
fi

# Hard-code PROD namespace — never deploy to any other namespace.
if [[ "$NAMESPACE" != "triage-prod" ]]; then
  echo "Refusing deploy: namespace must be triage-prod (got: ${NAMESPACE})" >&2
  exit 1
fi

# Hard-code PROD overlay — never apply any other overlay.
if [[ "$OVERLAY" != "$APPROVED_OVERLAY" ]]; then
  echo "Refusing deploy: DEPLOY_OVERLAY must be exactly ${APPROVED_OVERLAY} (got: ${OVERLAY})" >&2
  exit 1
fi

# ── Rollback helpers ──────────────────────────────────────────────────────────

verify_rollback_complete() {
  local actual
  actual=$(kubectl get deploy/ticket-triage -n "${NAMESPACE}" \
    -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || echo "__missing__")

  if [[ "${DEPLOYMENT_MUTATED}" == "true" ]]; then
    if [[ "${actual}" != "${PREV_IMAGE}" ]]; then
      echo "Rollback verification FAILED: running image='${actual}', expected PREV='${PREV_IMAGE}'" >&2
      return 1
    fi
  fi

  if [[ "${KUSTOMIZATION_MUTATED}" == "true" && "${DEPLOYMENT_MUTATED}" != "true" ]]; then
    # Only the kustomization file changed; deployment unchanged — verify consistency.
    if [[ "${actual}" != "${PREV_IMAGE}" ]]; then
      echo "Rollback verification FAILED: deployment image changed without apply (image='${actual}')" >&2
      return 1
    fi
  fi

  return 0
}

perform_rollback() {
  local reason="${1:-unknown}"

  if [[ "${ROLLBACK_IN_PROGRESS}" == "true" ]]; then
    echo "Rollback already in progress — skipping nested rollback" >&2
    return 1
  fi

  if [[ "${KUSTOMIZATION_MUTATED}" != "true" && "${DEPLOYMENT_MUTATED}" != "true" ]]; then
    # Nothing was mutated — nothing to roll back.
    return 0
  fi

  ROLLBACK_IN_PROGRESS=true
  echo "Initiating PROD rollback (reason: ${reason})..." >&2

  if [[ "${DEPLOYMENT_MUTATED}" == "true" ]]; then
    if [[ "${PREV_IMAGE}" == "none" ]]; then
      echo "No previous PROD image recorded — cannot restore deployment." >&2
      # Restore kustomization at minimum so the file is consistent.
      if [[ -f "${OVERLAY}/kustomization.yaml.backup" ]]; then
        mv "${OVERLAY}/kustomization.yaml.backup" "${OVERLAY}/kustomization.yaml"
        echo "kustomization.yaml restored from backup (deployment unchanged)." >&2
      fi
      return 1
    fi

    # Strategy: restore the kustomization backup and re-apply it.
    # This is safer than kubectl rollout undo when PROD has only one revision.
    if [[ -f "${OVERLAY}/kustomization.yaml.backup" ]]; then
      echo "Restoring kustomization.yaml from backup..." >&2
      mv "${OVERLAY}/kustomization.yaml.backup" "${OVERLAY}/kustomization.yaml"

      echo "Re-applying previous kustomization to revert PROD deployment..." >&2
      if ! kubectl apply -k "${OVERLAY}"; then
        echo "kubectl apply of previous kustomization failed — trying rollout undo as fallback." >&2
        if ! kubectl rollout undo deploy/ticket-triage -n "${NAMESPACE}"; then
          echo "Rollback FAILED: kubectl rollout undo also failed." >&2
          return 1
        fi
      fi
    else
      # No backup available — fall back to rollout undo.
      echo "No kustomization backup found — using kubectl rollout undo." >&2
      if ! kubectl rollout undo deploy/ticket-triage -n "${NAMESPACE}"; then
        echo "Rollback FAILED: kubectl rollout undo failed." >&2
        return 1
      fi
    fi

    if ! kubectl rollout status deploy/ticket-triage -n "${NAMESPACE}" --timeout=300s; then
      echo "Rollback FAILED: rollout did not become healthy within 300s." >&2
      return 1
    fi

  elif [[ "${KUSTOMIZATION_MUTATED}" == "true" ]]; then
    # Deployment was not applied; just restore the kustomization file.
    if [[ ! -f "${OVERLAY}/kustomization.yaml.backup" ]]; then
      echo "Rollback FAILED: kustomization.yaml.backup not found." >&2
      return 1
    fi
    mv "${OVERLAY}/kustomization.yaml.backup" "${OVERLAY}/kustomization.yaml"
    echo "kustomization.yaml restored (deployment was not mutated)." >&2
  fi

  if ! verify_rollback_complete; then
    return 1
  fi

  echo "PROD rollback completed successfully." >&2
  return 0
}

on_exit() {
  local ec=$?
  trap - EXIT
  if [[ $ec -ne 0 ]]; then
    if ! perform_rollback "${ec}"; then
      echo "::error::PROD rollback failed — manual intervention required!" >&2
      ec=1
    fi
  fi
  exit "$ec"
}

# ── Deployment ────────────────────────────────────────────────────────────────

echo "=== AWS PROD Deployment ==="
echo "Image:     ${IMAGE}"
echo "Namespace: ${NAMESPACE}"
echo "Overlay:   ${OVERLAY}"

cd "${OVERLAY}"

# Record current PROD image BEFORE any mutation (rollback target).
PREV_IMAGE=$(kubectl get deploy/ticket-triage -n "${NAMESPACE}" \
  -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || echo "none")
echo "Previous PROD image: ${PREV_IMAGE}"

# Idempotency: skip if already deployed.
if [[ "${PREV_IMAGE}" == "${IMAGE}" ]]; then
  echo "Image already deployed — PROD deployment is a no-op."
  exit 0
fi

# Install rollback trap AFTER recording PREV_IMAGE (so on_exit has a valid target).
trap on_exit EXIT

# Back up kustomization before any mutation.
cp kustomization.yaml kustomization.yaml.backup

kustomize edit set image "ticket-triage-api=${IMAGE}" || {
  echo "kustomize not found in PATH — downloading v5.4.3..." >&2
  curl -sL \
    https://github.com/kubernetes-sigs/kustomize/releases/download/kustomize%2Fv5.4.3/kustomize_v5.4.3_linux_amd64.tar.gz \
    | tar -xz -C /tmp
  sudo mv /tmp/kustomize /usr/local/bin/kustomize
  kustomize edit set image "ticket-triage-api=${IMAGE}"
}
KUSTOMIZATION_MUTATED=true

kubectl apply -k .
DEPLOYMENT_MUTATED=true

if ! kubectl rollout status deploy/ticket-triage -n "${NAMESPACE}" --timeout=300s; then
  echo "Rollout failed — initiating rollback." >&2
  exit 1
fi

ACTUAL=$(kubectl get deploy/ticket-triage -n "${NAMESPACE}" \
  -o jsonpath='{.spec.template.spec.containers[0].image}')
echo "Deployed image: ${ACTUAL}"

if [[ "${ACTUAL}" != "${IMAGE}" ]]; then
  echo "Image mismatch after rollout (expected: ${IMAGE}, got: ${ACTUAL})" >&2
  exit 1
fi

# ── Commit success ────────────────────────────────────────────────────────────
rm -f kustomization.yaml.backup
KUSTOMIZATION_MUTATED=false
DEPLOYMENT_MUTATED=false
trap - EXIT

echo "=== PROD deployment successful ==="
echo "Image:     ${IMAGE}"
echo "Namespace: ${NAMESPACE}"
