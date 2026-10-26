#!/usr/bin/env bash
# Mocked tests for ssm-wait-command-invocation.sh (no AWS calls).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WAIT_SCRIPT="${ROOT}/ssm-wait-command-invocation.sh"
WORKDIR=$(mktemp -d)

pass=0
fail=0

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

setup_mock_aws() {
  cat > "${WORKDIR}/aws" <<AWS
#!/usr/bin/env bash
STATE="${WORKDIR}/wait-state"
case "\${MOCK_WAIT_MODE}" in
  access_denied)
    echo "An error occurred (AccessDeniedException) when calling the GetCommandInvocation operation: User is not authorized" >&2
    exit 254
    ;;
  transient_then_success)
    n=0
    [[ -f "\${STATE}" ]] && n=\$(<"\${STATE}")
    n=\$((n + 1))
    echo "\${n}" > "\${STATE}"
    if [[ "\${n}" -lt 3 ]]; then
      echo "An error occurred (InvocationDoesNotExist) when calling the GetCommandInvocation operation: Invocation does not exist" >&2
      exit 254
    fi
    echo '{"Status":"Success","StandardOutputContent":"ok","ResponseCode":0}'
    exit 0
    ;;
  transient_exhausted)
    echo "An error occurred (InvocationDoesNotExist) when calling the GetCommandInvocation operation: not yet" >&2
    exit 254
    ;;
  success)
    echo '{"Status":"Success","StandardOutputContent":"done","ResponseCode":0}'
    exit 0
    ;;
esac
echo "unknown mock mode" >&2
exit 99
AWS
  chmod +x "${WORKDIR}/aws"
}

run_wait() {
  rm -f "${WORKDIR}/wait-state"
  PATH="${WORKDIR}:${PATH}" \
  POLL_INTERVAL=0 \
  MAX_TRANSIENT_RETRIES="${MAX_TRANSIENT_RETRIES:-24}" \
  bash "${WAIT_SCRIPT}" "cmd-test" "i-test" "${TIMEOUT_SECONDS:-60}"
}

setup_mock_aws

set +e
out=$(MOCK_WAIT_MODE=access_denied run_wait 2>&1)
ec=$?
set -e
assert_ne "$ec" "0" "AccessDenied fails promptly"
assert_eq "$(grep -c 'AccessDeniedException' <<<"$out" || true)" "1" "AccessDenied reported"

set +e
out=$(MOCK_WAIT_MODE=transient_then_success run_wait 2>&1)
ec=$?
set -e
assert_eq "$ec" "0" "transient errors then success"
assert_eq "$(grep -c 'Transient SSM API error' <<<"$out" || true)" "2" "two transient retries"

set +e
out=$(MOCK_WAIT_MODE=transient_exhausted MAX_TRANSIENT_RETRIES=2 TIMEOUT_SECONDS=60 run_wait 2>&1)
ec=$?
set -e
assert_ne "$ec" "0" "transient retry limit exceeded"
assert_eq "$(grep -c 'exceeded transient retry limit' <<<"$out" || true)" "1" "retry limit message"

set +e
out=$(MOCK_WAIT_MODE=success run_wait 2>&1)
ec=$?
set -e
assert_eq "$ec" "0" "success path"
assert_eq "$(grep -c 'done' <<<"$out" || true)" "1" "stdout from invocation"

rm -rf "${WORKDIR}"
echo "----"
echo "wait tests: ${pass} passed, ${fail} failed"
[[ "$fail" -eq 0 ]]
