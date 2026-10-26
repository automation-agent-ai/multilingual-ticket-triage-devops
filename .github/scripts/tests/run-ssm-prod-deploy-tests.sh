#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────────────────────
# run-ssm-prod-deploy-tests.sh
#
# Mocked failure-injection tests for ssm-remote-kustomize-deploy-prod.sh.
# No real cluster, SSM, or AWS access — all kubectl/kustomize calls are mocked.
#
# Test scenarios:
#   1. test_success_path               — nominal deployment succeeds
#   2. test_apply_failure_restores     — kubectl apply fails; kustomization restored
#   3. test_rollout_failure_rollback   — rollout fails; previous kustomization re-applied
#   4. test_image_mismatch_rollback    — post-rollout image mismatch; rollback triggered
#   5. test_rollback_failure_loud      — rollback also fails; exits non-zero loudly
#   6. test_rejects_wrong_namespace    — refuses non-triage-prod namespace
#   7. test_rejects_wrong_overlay      — refuses unauthorized overlay path
#   8. test_rejects_bad_image_format   — refuses malformed image reference
#   9. test_idempotent_same_image      — exits 0 immediately if already deployed
# ──────────────────────────────────────────────────────────────────────────────
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEPLOY_SCRIPT="${ROOT}/ssm-remote-kustomize-deploy-prod.sh"

IMAGE="ghcr.io/automation-agent-ai/multilingual-ticket-triage-devops:aws-sha-$(printf '%040d' 1)"
PREV_IMAGE="ghcr.io/automation-agent-ai/multilingual-ticket-triage-devops:aws-sha-$(printf '%040d' 0)"
WORKDIR=""

pass=0
fail=0

# ── Assertion helpers ────────────────────────────────────────────────────────

assert_eq() {
  local got="$1" want="$2" msg="$3"
  if [[ "$got" == "$want" ]]; then
    pass=$((pass + 1))
    echo "  PASS: ${msg}"
  else
    fail=$((fail + 1))
    echo "  FAIL: ${msg} (got='${got}' want='${want}')" >&2
  fi
}

assert_ne() {
  local got="$1" want="$2" msg="$3"
  if [[ "$got" != "$want" ]]; then
    pass=$((pass + 1))
    echo "  PASS: ${msg}"
  else
    fail=$((fail + 1))
    echo "  FAIL: ${msg} (unexpected value='${got}')" >&2
  fi
}

assert_contains() {
  local haystack="$1" needle="$2" msg="$3"
  if echo "$haystack" | grep -qF "$needle"; then
    pass=$((pass + 1))
    echo "  PASS: ${msg}"
  else
    fail=$((fail + 1))
    echo "  FAIL: ${msg} (needle='${needle}' not found)" >&2
  fi
}

# ── Setup helpers ─────────────────────────────────────────────────────────────

setup_overlay() {
  WORKDIR=$(mktemp -d)
  mkdir -p "${WORKDIR}/overlay"
  echo "images: []" > "${WORKDIR}/overlay/kustomization.yaml"
  mkdir -p "${WORKDIR}/bin"
  export SSM_DEPLOY_TEST_HOOK=1
  export SSM_DEPLOY_APPROVED_OVERLAY_OVERRIDE="${WORKDIR}/overlay"
}

# Standard kubectl mock — behaviour controlled by MOCK_SCENARIO and state file.
write_kubectl_mock() {
  cat > "${WORKDIR}/bin/kubectl" <<'KUBECTL'
#!/usr/bin/env bash
set -euo pipefail
STATE_FILE="${MOCK_STATE_FILE:?}"
rollout_status_fail=0
apply_fail=0
if [[ -f "${STATE_FILE}" ]]; then
  # shellcheck disable=SC1090
  source "${STATE_FILE}"
fi

case "$*" in
  *rollout\ undo*)
    echo "undo=1" >> "${STATE_FILE}"
    exit 0
    ;;
  *rollout\ status*)
    if [[ -f "${STATE_FILE}" ]] && grep -q '^undo=1' "${STATE_FILE}"; then
      exit 0
    fi
    if [[ "${rollout_status_fail}" == "1" ]]; then
      exit 1
    fi
    exit 0
    ;;
  *apply*)
    if [[ "${apply_fail}" == "1" ]]; then
      echo "apply failed" >&2
      exit 1
    fi
    echo "applied=1" >> "${STATE_FILE}"
    exit 0
    ;;
  *get\ deploy*)
    get_n=0
    [[ -f "${STATE_FILE}" ]] && get_n=$(grep -c '^get=' "${STATE_FILE}" 2>/dev/null || echo 0)
    get_n=$((get_n + 1))
    echo "get=${get_n}" >> "${STATE_FILE}"
    case "${MOCK_SCENARIO:-success}" in
      image_mismatch)
        # Second get (post-rollout check) returns wrong image
        if [[ "${get_n}" -ge 2 ]]; then
          echo "ghcr.io/automation-agent-ai/multilingual-ticket-triage-devops:aws-sha-$(printf '%040d' 9)"
        else
          echo "${PREV_IMAGE}"
        fi
        ;;
      success)
        if [[ "${get_n}" -ge 2 ]]; then
          echo "${NEW_IMAGE}"
        else
          echo "${PREV_IMAGE}"
        fi
        ;;
      *)
        echo "${PREV_IMAGE}"
        ;;
    esac
    exit 0
    ;;
esac
echo "unexpected kubectl invocation: $*" >&2
exit 99
KUBECTL
  chmod +x "${WORKDIR}/bin/kubectl"

  cat > "${WORKDIR}/bin/kustomize" <<'KUSTOMIZE'
#!/usr/bin/env bash
# Simulate: appends mutation marker
echo "mutated=true" >> kustomization.yaml
exit 0
KUSTOMIZE
  chmod +x "${WORKDIR}/bin/kustomize"
}

run_deploy() {
  local ns="${1:-triage-prod}"
  export DEPLOY_IMAGE="${IMAGE}"
  export DEPLOY_NAMESPACE="${ns}"
  export DEPLOY_OVERLAY="${WORKDIR}/overlay"
  export PREV_IMAGE NEW_IMAGE="${IMAGE}" MOCK_SCENARIO MOCK_STATE_FILE="${WORKDIR}/state"
  export PATH="${WORKDIR}/bin:${PATH}"
  bash "${DEPLOY_SCRIPT}" 2>&1
}

# ── Test cases ────────────────────────────────────────────────────────────────

test_success_path() {
  echo "▶ test_success_path"
  setup_overlay
  write_kubectl_mock
  export MOCK_SCENARIO=success
  set +e
  out=$(run_deploy)
  ec=$?
  set -e
  assert_eq "$ec" "0" "success path exits zero"
  assert_contains "$out" "PROD deployment successful" "success message present"
  assert_eq "$(test -f "${WORKDIR}/overlay/kustomization.yaml.backup" && echo yes || echo no)" \
    "no" "backup cleaned up on success"
  rm -rf "${WORKDIR}"
}

test_apply_failure_restores_kustomization() {
  echo "▶ test_apply_failure_restores_kustomization"
  setup_overlay
  write_kubectl_mock
  cp "${WORKDIR}/overlay/kustomization.yaml" "${WORKDIR}/overlay/kustomization.yaml.orig"
  # Override kubectl to fail on apply
  cat > "${WORKDIR}/bin/kubectl" <<'KUBECTL'
#!/usr/bin/env bash
set -euo pipefail
case "$*" in
  *get\ deploy*) echo "${PREV_IMAGE}"; exit 0 ;;
  *apply*)       echo "apply failed" >&2; exit 1 ;;
esac
exit 99
KUBECTL
  chmod +x "${WORKDIR}/bin/kubectl"
  export MOCK_SCENARIO=apply_fail
  set +e
  run_deploy >/dev/null
  ec=$?
  set -e
  assert_ne "$ec" "0" "apply failure exits non-zero"
  assert_eq \
    "$(cat "${WORKDIR}/overlay/kustomization.yaml")" \
    "$(cat "${WORKDIR}/overlay/kustomization.yaml.orig")" \
    "kustomization restored after apply failure"
  assert_eq "$(test -f "${WORKDIR}/overlay/kustomization.yaml.backup" && echo yes || echo no)" \
    "no" "backup consumed during restore"
  rm -rf "${WORKDIR}"
}

test_rollout_failure_rollback() {
  echo "▶ test_rollout_failure_rollback"
  setup_overlay
  write_kubectl_mock
  cp "${WORKDIR}/overlay/kustomization.yaml" "${WORKDIR}/overlay/kustomization.yaml.orig"
  # kubectl get returns PREV_IMAGE after rollback apply (simulates restored state)
  cat > "${WORKDIR}/bin/kubectl" <<'KUBECTL'
#!/usr/bin/env bash
set -euo pipefail
STATE_FILE="${MOCK_STATE_FILE:?}"
rollout_seq=0
[[ -f "${STATE_FILE}" ]] && rollout_seq=$(grep -c '^rollout=' "${STATE_FILE}" 2>/dev/null || echo 0)
case "$*" in
  *get\ deploy*)
    get_n=0
    [[ -f "${STATE_FILE}" ]] && get_n=$(grep -c '^get=' "${STATE_FILE}" 2>/dev/null || echo 0)
    get_n=$((get_n + 1))
    echo "get=${get_n}" >> "${STATE_FILE}"
    # Always return PREV_IMAGE (before deploy + after rollback)
    echo "${PREV_IMAGE}"
    exit 0
    ;;
  *apply*)
    echo "applied=1" >> "${STATE_FILE}"
    exit 0
    ;;
  *rollout\ status*)
    echo "rollout=${rollout_seq}" >> "${STATE_FILE}"
    rollout_seq=$((rollout_seq + 1))
    # First rollout status call fails (deploy), second succeeds (rollback)
    if [[ "${rollout_seq}" -le 1 ]]; then
      exit 1
    fi
    exit 0
    ;;
esac
exit 99
KUBECTL
  chmod +x "${WORKDIR}/bin/kubectl"
  export MOCK_SCENARIO=rollout_fail
  set +e
  out=$(run_deploy)
  ec=$?
  set -e
  assert_ne "$ec" "0" "rollout failure exits non-zero"
  assert_contains "$out" "Initiating PROD rollback" "rollback initiated message"
  assert_eq \
    "$(cat "${WORKDIR}/overlay/kustomization.yaml")" \
    "$(cat "${WORKDIR}/overlay/kustomization.yaml.orig")" \
    "kustomization restored after rollout failure"
  rm -rf "${WORKDIR}"
}

test_image_mismatch_rollback() {
  echo "▶ test_image_mismatch_rollback"
  setup_overlay
  write_kubectl_mock
  export MOCK_SCENARIO=image_mismatch
  set +e
  out=$(run_deploy)
  ec=$?
  set -e
  assert_ne "$ec" "0" "image mismatch exits non-zero"
  assert_contains "$out" "Image mismatch after rollout" "mismatch message present"
  rm -rf "${WORKDIR}"
}

test_rollback_failure_loud() {
  echo "▶ test_rollback_failure_loud"
  setup_overlay
  write_kubectl_mock
  # Override kubectl: apply succeeds, rollout always fails, rollback apply also fails
  cat > "${WORKDIR}/bin/kubectl" <<'KUBECTL'
#!/usr/bin/env bash
set -euo pipefail
case "$*" in
  *get\ deploy*)   echo "${PREV_IMAGE}"; exit 0 ;;
  *apply*)         echo "apply result" ; exit 1 ;;
  *rollout\ undo*) echo "undo nope" >&2; exit 1 ;;
  *rollout\ status*) exit 1 ;;
esac
exit 99
KUBECTL
  chmod +x "${WORKDIR}/bin/kubectl"
  export MOCK_SCENARIO=rollback_fail
  set +e
  out=$(run_deploy)
  ec=$?
  set -e
  assert_ne "$ec" "0" "rollback failure exits non-zero"
  assert_contains "$out" "rollback" "rollback attempt mentioned"
  rm -rf "${WORKDIR}"
}

test_rejects_wrong_namespace() {
  echo "▶ test_rejects_wrong_namespace"
  setup_overlay
  set +e
  out=$(run_deploy "triage-dev")  # Wrong namespace — must be triage-prod
  ec=$?
  set -e
  assert_ne "$ec" "0" "wrong namespace exits non-zero"
  assert_contains "$out" "namespace must be triage-prod" "namespace error message"
  rm -rf "${WORKDIR}"
}

test_rejects_wrong_overlay() {
  echo "▶ test_rejects_wrong_overlay"
  setup_overlay
  set +e
  out=$(
    DEPLOY_IMAGE="${IMAGE}" \
    DEPLOY_NAMESPACE="triage-prod" \
    DEPLOY_OVERLAY="/tmp/malicious-overlay" \
    SSM_DEPLOY_TEST_HOOK=1 \
    SSM_DEPLOY_APPROVED_OVERLAY_OVERRIDE="${WORKDIR}/overlay" \
    PATH="${WORKDIR}/bin:${PATH}" \
    bash "${DEPLOY_SCRIPT}" 2>&1
  )
  ec=$?
  set -e
  assert_ne "$ec" "0" "wrong overlay exits non-zero"
  assert_contains "$out" "DEPLOY_OVERLAY must be exactly" "overlay error message"
  rm -rf "${WORKDIR}"
}

test_rejects_bad_image_format() {
  echo "▶ test_rejects_bad_image_format"
  setup_overlay
  set +e
  out=$(
    DEPLOY_IMAGE="ghcr.io/automation-agent-ai/multilingual-ticket-triage-devops:latest" \
    DEPLOY_NAMESPACE="triage-prod" \
    DEPLOY_OVERLAY="${WORKDIR}/overlay" \
    SSM_DEPLOY_TEST_HOOK=1 \
    SSM_DEPLOY_APPROVED_OVERLAY_OVERRIDE="${WORKDIR}/overlay" \
    PATH="${WORKDIR}/bin:${PATH}" \
    bash "${DEPLOY_SCRIPT}" 2>&1
  )
  ec=$?
  set -e
  assert_ne "$ec" "0" "bad image format exits non-zero"
  assert_contains "$out" "Invalid DEPLOY_IMAGE format" "image format error message"
  rm -rf "${WORKDIR}"
}

test_idempotent_same_image() {
  echo "▶ test_idempotent_same_image"
  setup_overlay
  # kubectl mock: returns the SAME image as DEPLOY_IMAGE (already deployed)
  cat > "${WORKDIR}/bin/kubectl" <<'KUBECTL'
#!/usr/bin/env bash
set -euo pipefail
case "$*" in
  *get\ deploy*) echo "${DEPLOY_IMAGE}"; exit 0 ;;
esac
exit 99
KUBECTL
  chmod +x "${WORKDIR}/bin/kubectl"
  export MOCK_SCENARIO=idempotent
  set +e
  out=$(run_deploy)
  ec=$?
  set -e
  assert_eq "$ec" "0" "idempotent deploy exits zero"
  assert_contains "$out" "no-op" "no-op message when already deployed"
  rm -rf "${WORKDIR}"
}

# ── Run all tests ─────────────────────────────────────────────────────────────

echo "=== PROD Deploy Helper Tests ==="
echo ""

test_success_path
test_apply_failure_restores_kustomization
test_rollout_failure_rollback
test_image_mismatch_rollback
test_rollback_failure_loud
test_rejects_wrong_namespace
test_rejects_wrong_overlay
test_rejects_bad_image_format
test_idempotent_same_image

echo ""
echo "────────────────────────────────────────────────"
echo "PROD deploy tests: ${pass} passed, ${fail} failed"
[[ "$fail" -eq 0 ]]
