#!/usr/bin/env bash
# Executed on the EC2 host via SSM (stdin or file). Image and paths come from env.
set -euo pipefail

if [[ "${SSM_DEPLOY_TEST_HOOK:-}" == "1" && -n "${SSM_DEPLOY_APPROVED_OVERLAY_OVERRIDE:-}" ]]; then
  readonly APPROVED_OVERLAY="${SSM_DEPLOY_APPROVED_OVERLAY_OVERRIDE}"
else
  readonly APPROVED_OVERLAY="/home/ubuntu/workspaces/multilingual-ticket-triage-devops/k8s/overlays/aws-dev"
fi

IMAGE="${DEPLOY_IMAGE:?DEPLOY_IMAGE must be set}"
NAMESPACE="${DEPLOY_NAMESPACE:?DEPLOY_NAMESPACE must be set}"
OVERLAY="${DEPLOY_OVERLAY:?DEPLOY_OVERLAY must be set}"

PREV_IMAGE=""
KUSTOMIZATION_MUTATED=false
DEPLOYMENT_MUTATED=false
ROLLBACK_IN_PROGRESS=false

if [[ ! "$IMAGE" =~ ^ghcr\.io/automation-agent-ai/multilingual-ticket-triage-devops:aws-sha-[0-9a-f]{40}$ ]]; then
  echo "Invalid DEPLOY_IMAGE format (refusing to deploy)" >&2
  exit 1
fi

if [[ "$NAMESPACE" != "triage-dev" ]]; then
  echo "Refusing deploy: namespace must be triage-dev (got: ${NAMESPACE})" >&2
  exit 1
fi

if [[ "$OVERLAY" != "$APPROVED_OVERLAY" ]]; then
  echo "Refusing deploy: DEPLOY_OVERLAY must be exactly ${APPROVED_OVERLAY} (got: ${OVERLAY})" >&2
  exit 1
fi

verify_rollback_complete() {
  local actual
  actual=$(kubectl get deploy/ticket-triage -n "${NAMESPACE}" \
    -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || echo "__missing__")

  if [[ "${DEPLOYMENT_MUTATED}" == "true" ]]; then
    if [[ "${actual}" != "${PREV_IMAGE}" ]]; then
      echo "Rollback verification failed: deployment image is '${actual}', expected '${PREV_IMAGE}'" >&2
      return 1
    fi
  fi

  if [[ "${KUSTOMIZATION_MUTATED}" == "true" && "${DEPLOYMENT_MUTATED}" != "true" ]]; then
    if [[ "${actual}" != "${PREV_IMAGE}" ]]; then
      echo "Rollback verification failed: deployment image changed without successful apply rollback path" >&2
      return 1
    fi
  fi

  return 0
}

perform_rollback() {
  local reason="${1:-unknown}"
  if [[ "${ROLLBACK_IN_PROGRESS}" == "true" ]]; then
    return 1
  fi
  if [[ "${KUSTOMIZATION_MUTATED}" != "true" && "${DEPLOYMENT_MUTATED}" != "true" ]]; then
    return 0
  fi

  ROLLBACK_IN_PROGRESS=true
  echo "Performing rollback (${reason})..." >&2

  if [[ "${DEPLOYMENT_MUTATED}" == "true" ]]; then
    if ! kubectl rollout undo deploy/ticket-triage -n "${NAMESPACE}"; then
      echo "Rollback failed: kubectl rollout undo" >&2
      return 1
    fi
    if ! kubectl rollout status deploy/ticket-triage -n "${NAMESPACE}" --timeout=300s; then
      echo "Rollback failed: rollout status after undo" >&2
      return 1
    fi
  fi

  if [[ "${KUSTOMIZATION_MUTATED}" == "true" ]]; then
    if [[ ! -f "${OVERLAY}/kustomization.yaml.backup" ]]; then
      echo "Rollback failed: missing kustomization.yaml.backup" >&2
      return 1
    fi
    mv "${OVERLAY}/kustomization.yaml.backup" "${OVERLAY}/kustomization.yaml"
  fi

  if ! verify_rollback_complete; then
    return 1
  fi

  echo "Rollback completed successfully" >&2
  return 0
}

on_exit() {
  local ec=$?
  trap - EXIT
  if [[ $ec -ne 0 ]]; then
    if ! perform_rollback "${ec}"; then
      ec=1
    fi
  fi
  exit "$ec"
}

echo "=== AWS DEV Deployment ==="
echo "Image: ${IMAGE}"
echo "Namespace: ${NAMESPACE}"
echo "Overlay: ${OVERLAY}"

cd "${OVERLAY}"

PREV_IMAGE=$(kubectl get deploy/ticket-triage -n "${NAMESPACE}" \
  -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || echo "none")
echo "Previous: ${PREV_IMAGE}"

trap on_exit EXIT

cp kustomization.yaml kustomization.yaml.backup

kustomize edit set image "ticket-triage-api=${IMAGE}" || {
  curl -sL https://github.com/kubernetes-sigs/kustomize/releases/download/kustomize%2Fv5.4.3/kustomize_v5.4.3_linux_amd64.tar.gz \
    | tar -xz -C /tmp
  sudo mv /tmp/kustomize /usr/local/bin/
  kustomize edit set image "ticket-triage-api=${IMAGE}"
}
KUSTOMIZATION_MUTATED=true

kubectl apply -k .
DEPLOYMENT_MUTATED=true

if ! kubectl rollout status deploy/ticket-triage -n "${NAMESPACE}" --timeout=300s; then
  echo "Rollout failed" >&2
  exit 1
fi

ACTUAL=$(kubectl get deploy/ticket-triage -n "${NAMESPACE}" \
  -o jsonpath='{.spec.template.spec.containers[0].image}')
echo "Deployed: ${ACTUAL}"

if [[ "${ACTUAL}" != "${IMAGE}" ]]; then
  echo "Image mismatch after rollout (expected ${IMAGE})" >&2
  exit 1
fi

rm -f kustomization.yaml.backup
KUSTOMIZATION_MUTATED=false
DEPLOYMENT_MUTATED=false
trap - EXIT
echo "Deployment successful"
