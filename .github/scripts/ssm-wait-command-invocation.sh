#!/usr/bin/env bash
# Poll SSM get-command-invocation until terminal state or timeout (GitHub Actions runner).
set -euo pipefail

CMD_ID="${1:?usage: ssm-wait-command-invocation.sh <command-id> <instance-id> [timeout_seconds]}"
INSTANCE_ID="${2:?usage: ssm-wait-command-invocation.sh <command-id> <instance-id> [timeout_seconds]}"
TIMEOUT_SECONDS="${3:-600}"
POLL_INTERVAL="${POLL_INTERVAL:-5}"
MAX_TRANSIENT_RETRIES="${MAX_TRANSIENT_RETRIES:-24}"

deadline=$(( $(date +%s) + TIMEOUT_SECONDS ))
last_status="unknown"
transient_retries=0

sanitize_aws_message() {
  local msg="$1"
  msg=$(sed -E \
    -e 's/(AWS_ACCESS_KEY_ID|AWS_SECRET_ACCESS_KEY|AWS_SESSION_TOKEN)=([^ ]+)/\1=[REDACTED]/g' \
    -e 's/(access key|secret key) [^ ]+/[REDACTED]/gi' \
    <<<"${msg}")
  printf '%s' "${msg}"
}

aws_error_code() {
  local msg="$1"
  if [[ "${msg}" =~ \(([A-Za-z0-9]+)\) ]]; then
    printf '%s' "${BASH_REMATCH[1]}"
    return 0
  fi
  printf '%s' "Unknown"
}

is_non_retryable_aws_error() {
  local code="$1"
  case "${code}" in
    AccessDeniedException|UnauthorizedOperation|UnrecognizedClientException|InvalidClientTokenId|ExpiredTokenException|InvalidInstanceId|ValidationException|ResourceNotFoundException)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

is_transient_aws_error() {
  local code="$1"
  case "${code}" in
    InvocationDoesNotExist|ThrottlingException|Throttling|RequestLimitExceeded|ServiceUnavailable|InternalServerError|InternalFailure|TooManyRequestsException)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

handle_aws_cli_failure() {
  local err="$1"
  local code
  code=$(aws_error_code "${err}")
  err=$(sanitize_aws_message "${err}")

  if is_non_retryable_aws_error "${code}"; then
    echo "::error::SSM get-command-invocation failed (${code}): ${err}" >&2
    exit 1
  fi

  if is_transient_aws_error "${code}"; then
    transient_retries=$(( transient_retries + 1 ))
    if (( transient_retries > MAX_TRANSIENT_RETRIES )); then
      echo "::error::SSM get-command-invocation exceeded transient retry limit (${MAX_TRANSIENT_RETRIES}); last error (${code}): ${err}" >&2
      exit 1
    fi
    echo "Transient SSM API error (${code}), retry ${transient_retries}/${MAX_TRANSIENT_RETRIES}..."
    sleep "${POLL_INTERVAL}"
    return 0
  fi

  transient_retries=$(( transient_retries + 1 ))
  if (( transient_retries > MAX_TRANSIENT_RETRIES )); then
    echo "::error::SSM get-command-invocation failed after retries (${code}): ${err}" >&2
    exit 1
  fi
  echo "SSM API error (${code}), retry ${transient_retries}/${MAX_TRANSIENT_RETRIES}..."
  sleep "${POLL_INTERVAL}"
}

while true; do
  now=$(date +%s)
  if (( now >= deadline )); then
    echo "::error::SSM command ${CMD_ID} timed out after ${TIMEOUT_SECONDS}s (last status: ${last_status})"
    exit 124
  fi

  if ! raw=$(aws ssm get-command-invocation \
    --command-id "${CMD_ID}" \
    --instance-id "${INSTANCE_ID}" \
    --output json 2>&1); then
    handle_aws_cli_failure "${raw}"
    continue
  fi

  transient_retries=0

  if ! jq -e . >/dev/null 2>&1 <<<"${raw}"; then
    handle_aws_cli_failure "Invalid JSON from get-command-invocation: ${raw}"
    continue
  fi

  status=$(jq -r '.Status // empty' <<<"${raw}")
  last_status="${status:-unknown}"

  case "${status}" in
    Pending|InProgress|Delayed)
      echo "SSM status: ${status}"
      sleep "${POLL_INTERVAL}"
      ;;
    Success)
      echo "SSM status: Success"
      jq -r '.StandardOutputContent // empty' <<<"${raw}"
      rc=$(jq -r '.ResponseCode // 0' <<<"${raw}")
      if [[ "${rc}" != "0" ]]; then
        echo "::error::SSM reported Success but ResponseCode=${rc}" >&2
        jq -r '.StandardErrorContent // empty' <<<"${raw}" >&2
        exit "${rc}"
      fi
      exit 0
      ;;
    Failed|Cancelled|TimedOut)
      echo "::error::SSM command ${CMD_ID} finished with status: ${status}" >&2
      jq -r '.StandardOutputContent // empty' <<<"${raw}"
      echo "--- stderr ---" >&2
      jq -r '.StandardErrorContent // empty' <<<"${raw}" >&2
      rc=$(jq -r '.ResponseCode // 1' <<<"${raw}")
      exit "${rc}"
      ;;
    "")
      echo "Waiting for SSM status..."
      sleep "${POLL_INTERVAL}"
      ;;
    *)
      echo "::warning::Unexpected SSM status: ${status}"
      sleep "${POLL_INTERVAL}"
      ;;
  esac
done
