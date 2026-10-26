#!/usr/bin/env bash
# Mocked failure-injection tests for ssm-remote-kustomize-deploy.sh (no cluster/SSM).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEPLOY_SCRIPT="${ROOT}/ssm-remote-kustomize-deploy.sh"
IMAGE="ghcr.io/automation-agent-ai/multilingual-ticket-triage-devops:aws-sha-$(printf '%040d' 1)"
PREV_IMAGE="ghcr.io/automation-agent-ai/multilingual-ticket-triage-devops:aws-sha-$(printf '%040d' 0)"
WORKDIR=""

pass=0
fail=0

assert_eq() {
  local got="$1" want="$2" msg="$3"
  if [[ "$got" == "$want" ]]; then
    pass=$((pass + 1))
    echo "PASS: ${msg}"
  else
    fail=$((fail + 1))
    echo "FAIL: ${msg} (got=${got} want=${want})" >&2
  fi
}

assert_ne() {
  local got="$1" want="$2" msg="$3"
  if [[ "$got" != "$want" ]]; then
    pass=$((pass + 1))
    echo "PASS: ${msg}"
  else
    fail=$((fail + 1))
    echo "FAIL: ${msg} (got=${got})" >&2
  fi
}

setup_overlay() {
  WORKDIR=$(mktemp -d)
  mkdir -p "${WORKDIR}/overlay"
  echo "images: []" > "${WORKDIR}/overlay/kustomization.yaml"
  mkdir -p "${WORKDIR}/bin"
  export SSM_DEPLOY_TEST_HOOK=1
  export SSM_DEPLOY_APPROVED_OVERLAY_OVERRIDE="${WORKDIR}/overlay"
}

write_kubectl_mock() {
  cat > "${WORKDIR}/bin/kubectl" <<'KUBECTL'
#!/usr/bin/env bash
set -euo pipefail
STATE_FILE="${MOCK_STATE_FILE:?}"
rollout_status_fail=0
if [[ -f "${STATE_FILE}" ]]; then
  # shellcheck disable=SC1090
  source "${STATE_FILE}"
fi

case "$*" in
  *rollout\ undo*)
    echo "undo=1" > "${STATE_FILE}"
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
    echo "applied=1" >> "${STATE_FILE}"
    exit 0
    ;;
  *get\ deploy*)
    get_n=0
    [[ -f "${STATE_FILE}" ]] && get_n=$(grep -c '^get=' "${STATE_FILE}" 2>/dev/null || echo 0)
    get_n=$((get_n + 1))
    echo "get=${get_n}" >> "${STATE_FILE}"
    if [[ "${MOCK_SCENARIO}" == "image_mismatch" && "${get_n}" -eq 2 ]]; then
      echo "ghcr.io/automation-agent-ai/multilingual-ticket-triage-devops:aws-sha-$(printf '%040d' 9)"
    elif [[ "${MOCK_SCENARIO}" == "success" && "${get_n}" -ge 2 ]]; then
      echo "${NEW_IMAGE}"
    else
      echo "${PREV_IMAGE}"
    fi
    exit 0
    ;;
esac
echo "unexpected kubectl: $*" >&2
exit 99
KUBECTL
  chmod +x "${WORKDIR}/bin/kubectl"

  cat > "${WORKDIR}/bin/kustomize" <<'KUSTOMIZE'
#!/usr/bin/env bash
echo "mutated: true" >> kustomization.yaml
exit 0
KUSTOMIZE
  chmod +x "${WORKDIR}/bin/kustomize"
}

run_deploy() {
  export DEPLOY_IMAGE="${IMAGE}"
  export DEPLOY_NAMESPACE="triage-dev"
  export DEPLOY_OVERLAY="${WORKDIR}/overlay"
  export PREV_IMAGE NEW_IMAGE="${IMAGE}" MOCK_SCENARIO MOCK_STATE_FILE="${WORKDIR}/state"
  export PATH="${WORKDIR}/bin:${PATH}"
  bash "${DEPLOY_SCRIPT}" 2>&1
}

test_rejects_bad_overlay() {
  setup_overlay
  set +e
  out=$(DEPLOY_IMAGE="${IMAGE}" DEPLOY_NAMESPACE="triage-dev" DEPLOY_OVERLAY="/tmp/evil" \
    SSM_DEPLOY_TEST_HOOK=1 SSM_DEPLOY_APPROVED_OVERLAY_OVERRIDE="${WORKDIR}/overlay" \
    PATH="${WORKDIR}/bin:${PATH}" bash "${DEPLOY_SCRIPT}" 2>&1)
  ec=$?
  set -e
  assert_ne "$ec" "0" "rejects unexpected overlay path"
  assert_eq "$(grep -c 'DEPLOY_OVERLAY must be exactly' <<<"$out" || true)" "1" "overlay error message"
  rm -rf "${WORKDIR}"
}

test_apply_failure_restores_kustomization() {
  setup_overlay
  write_kubectl_mock
  cp "${WORKDIR}/overlay/kustomization.yaml" "${WORKDIR}/overlay/kustomization.yaml.orig"
  cat > "${WORKDIR}/bin/kubectl" <<'KUBECTL'
#!/usr/bin/env bash
set -euo pipefail
case "$*" in
  *get\ deploy*) echo "${PREV_IMAGE}"; exit 0 ;;
  *apply*) exit 1 ;;
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
  assert_eq "$(cat "${WORKDIR}/overlay/kustomization.yaml")" "$(cat "${WORKDIR}/overlay/kustomization.yaml.orig")" "kustomization restored after apply failure"
  assert_eq "$(test -f "${WORKDIR}/overlay/kustomization.yaml.backup" && echo yes || echo no)" "no" "backup consumed on restore"
  rm -rf "${WORKDIR}"
}

test_rollout_failure_rolls_back() {
  setup_overlay
  write_kubectl_mock
  echo "rollout_status_fail=1" > "${WORKDIR}/state"
  export MOCK_SCENARIO=rollout_fail
  set +e
  run_deploy >/dev/null
  ec=$?
  set -e
  assert_ne "$ec" "0" "rollout failure exits non-zero"
  assert_eq "$(grep -c '^undo=1' "${WORKDIR}/state" || true)" "1" "rollout undo invoked"
  rm -rf "${WORKDIR}"
}

test_image_mismatch_triggers_rollback() {
  setup_overlay
  write_kubectl_mock
  export MOCK_SCENARIO=image_mismatch
  set +e
  out=$(run_deploy)
  ec=$?
  set -e
  assert_ne "$ec" "0" "image mismatch exits non-zero"
  assert_eq "$(grep -c 'Image mismatch after rollout' <<<"$out" || true)" "1" "image mismatch reported"
  assert_eq "$(grep -c '^undo=1' "${WORKDIR}/state" || true)" "1" "rollout undo on mismatch"
  rm -rf "${WORKDIR}"
}

test_rollback_failure_loud() {
  setup_overlay
  write_kubectl_mock
  echo "rollout_status_fail=1" > "${WORKDIR}/state"
  cat > "${WORKDIR}/bin/kubectl" <<'KUBECTL'
#!/usr/bin/env bash
set -euo pipefail
case "$*" in
  *get\ deploy*) echo "${NEW_IMAGE}"; exit 0 ;;
  *apply*) exit 0 ;;
  *rollout\ undo*) echo "nope" >&2; exit 1 ;;
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
  assert_eq "$(grep -c 'Rollback failed' <<<"$out" || true)" "1" "reports rollback failure"
  rm -rf "${WORKDIR}"
}

test_success_path() {
  setup_overlay
  write_kubectl_mock
  export MOCK_SCENARIO=success
  set +e
  out=$(run_deploy)
  ec=$?
  set -e
  assert_eq "$ec" "0" "success path exits zero"
  assert_eq "$(grep -c 'Deployment successful' <<<"$out" || true)" "1" "success message"
  rm -rf "${WORKDIR}"
}

test_rejects_bad_overlay
test_apply_failure_restores_kustomization
test_rollout_failure_rolls_back
test_image_mismatch_triggers_rollback
test_rollback_failure_loud
test_success_path

echo "----"
echo "deploy tests: ${pass} passed, ${fail} failed"
[[ "$fail" -eq 0 ]]
