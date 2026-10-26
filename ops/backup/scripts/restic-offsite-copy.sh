#!/usr/bin/env bash
# =============================================================================
# Liora — Restic offsite copy (local EBS → Hetzner REST)
# =============================================================================
# Copies all local snapshots for the backup host to the remote repository using
# restic copy (native skip for already-copied snapshots). Read-only verification
# via destination snapshot "original" metadata.
#
# Exit codes:
#   0 = All source snapshots replicated (copy may have skipped already-copied)
#   2 = Lock / concurrent backup or offsite copy
#   3 = Network / destination preflight failed after retries
#   4 = restic copy failed
#   5 = Post-copy verification failed (incomplete replication)
#   6 = Configuration / credential error
# =============================================================================
set -euo pipefail

SCRIPT_NAME="restic-offsite-copy"
LOCK_FILE="/run/liora-restic-backup/offsite.lock"
BACKUP_LOCK_FILE="/run/liora-restic-backup/backup.lock"

FROM_REPO="${RESTIC_FROM_REPOSITORY:-/var/backups/liora-restic}"
FROM_PASSWORD_FILE="${RESTIC_FROM_PASSWORD_FILE:-/etc/liora-backup/restic-password}"
TO_REPO="${RESTIC_REPOSITORY:-rest:http://100.86.92.91:8000/aws-ec2-restic/}"
TO_PASSWORD_FILE="${RESTIC_PASSWORD_FILE:-/etc/liora-backup/restic-password}"
REST_CREDENTIALS_FILE="${LIORA_RESTIC_REST_CREDENTIALS_FILE:-/etc/liora-backup/hetzner-rest-writer.env}"
BACKUP_HOST="${RESTIC_SNAPSHOT_HOST:-liora-aws-ec2}"
HETZNER_TAILSCALE_IP="${LIORA_HETZNER_TAILSCALE_IP:-100.86.92.91}"
HETZNER_REST_PORT="${LIORA_HETZNER_REST_PORT:-8000}"
CACHE_DIR="${RESTIC_CACHE_DIR:-/var/lib/liora-restic/cache}"

MAX_ATTEMPTS="${LIORA_OFFSITE_COPY_MAX_ATTEMPTS:-5}"
RETRY_BASE_SEC="${LIORA_OFFSITE_COPY_RETRY_BASE_SEC:-30}"

# Logging: journal when non-interactive
if [ -t 1 ]; then
    LOG_FILE="/tmp/${SCRIPT_NAME}-$(date -u +%Y%m%dT%H%M%SZ).log"
else
    LOG_FILE="/dev/stderr"
fi

log() {
    local msg="[$(date -u +%Y-%m-%dT%H:%M:%SZ)] [${SCRIPT_NAME}] $*"
    if [[ "${LOG_FILE}" == "/dev/stderr" ]]; then
        echo "$msg" >&2
    else
        echo "$msg" | tee -a "${LOG_FILE}"
    fi
}

log_error() {
    local msg="[$(date -u +%Y-%m-%dT%H:%M:%SZ)] [${SCRIPT_NAME}] ERROR: $*"
    if [[ "${LOG_FILE}" == "/dev/stderr" ]]; then
        echo "$msg" >&2
    else
        echo "$msg" | tee -a "${LOG_FILE}" >&2
    fi
}

load_rest_credentials() {
    if [ -n "${RESTIC_REST_USERNAME:-}" ] && [ -n "${RESTIC_REST_PASSWORD:-}" ]; then
        return 0
    fi

    if [ ! -f "${REST_CREDENTIALS_FILE}" ]; then
        log_error "REST credentials file not found: ${REST_CREDENTIALS_FILE}"
        exit 6
    fi

    local line key value
    while IFS= read -r line || [ -n "${line}" ]; do
        line="${line%%#*}"
        line="${line#"${line%%[![:space:]]*}"}"
        [ -z "${line}" ] && continue
        if [[ "${line}" != *=* ]]; then
            log_error "Malformed credentials file (expected KEY=VALUE)"
            exit 6
        fi
        key="${line%%=*}"
        value="${line#*=}"
        key="${key%"${key##*[![:space:]]}"}"
        value="${value#"${value%%[![:space:]]*}"}"
        value="${value%"${value##*[![:space:]]}"}"
        value="${value#\"}"
        value="${value%\"}"
        value="${value#\'}"
        value="${value%\'}"
        case "${key}" in
            RESTIC_REST_USER)
                if [ -z "${RESTIC_REST_USERNAME:-}" ]; then
                    export RESTIC_REST_USERNAME="${value}"
                fi
                ;;
            RESTIC_REST_PASSWORD)
                if [ -z "${RESTIC_REST_PASSWORD:-}" ]; then
                    export RESTIC_REST_PASSWORD="${value}"
                fi
                ;;
            *)
                log_error "Unexpected key in credentials file: ${key}"
                exit 6
                ;;
        esac
    done < "${REST_CREDENTIALS_FILE}"

    if [ -z "${RESTIC_REST_USERNAME:-}" ] || [ -z "${RESTIC_REST_PASSWORD:-}" ]; then
        log_error "REST credentials incomplete (need RESTIC_REST_USER and RESTIC_REST_PASSWORD)"
        exit 6
    fi
}

acquire_lock() {
    local lock_dir
    lock_dir="$(dirname "${LOCK_FILE}")"
    if [ ! -d "${lock_dir}" ]; then
        log_error "Runtime directory missing: ${lock_dir} (is liora-restic-backup RuntimeDirectory active?)"
        exit 6
    fi

    if [ -f "${BACKUP_LOCK_FILE}" ]; then
        local bpid
        bpid="$(cat "${BACKUP_LOCK_FILE}" 2>/dev/null || echo "")"
        if [ -n "${bpid}" ] && ps -p "${bpid}" > /dev/null 2>&1; then
            log_error "Local backup in progress (PID ${bpid}); refusing offsite copy"
            exit 2
        fi
    fi

    if [ -f "${LOCK_FILE}" ]; then
        local opid
        opid="$(cat "${LOCK_FILE}" 2>/dev/null || echo "unknown")"
        if ps -p "${opid}" > /dev/null 2>&1; then
            log_error "Offsite copy already running (PID ${opid})"
            exit 2
        fi
        log "Removing stale offsite lock"
        rm -f "${LOCK_FILE}"
    fi

    echo $$ > "${LOCK_FILE}"
    trap 'rm -f "${LOCK_FILE}"' EXIT
}

preflight_config() {
    if ! command -v restic >/dev/null 2>&1; then
        log_error "restic not installed"
        exit 6
    fi
    if [ ! -f "${FROM_PASSWORD_FILE}" ] || [ ! -f "${TO_PASSWORD_FILE}" ]; then
        log_error "Missing restic password file(s)"
        exit 6
    fi
    if [ ! -d "${FROM_REPO}" ]; then
        log_error "Source repository path not found: ${FROM_REPO}"
        exit 6
    fi
    mkdir -p "${CACHE_DIR}"
    export RESTIC_CACHE_DIR="${CACHE_DIR}"
}

wait_for_destination() {
    local attempt=1
    local delay="${RETRY_BASE_SEC}"
    while [ "${attempt}" -le "${MAX_ATTEMPTS}" ]; do
        if command -v tailscale >/dev/null 2>&1; then
            if tailscale ping -c 1 -timeout 5s "${HETZNER_TAILSCALE_IP}" >/dev/null 2>&1; then
                if timeout 5 bash -c "echo >/dev/tcp/${HETZNER_TAILSCALE_IP}/${HETZNER_REST_PORT}" 2>/dev/null; then
                    log "Destination reachable (Tailscale + TCP ${HETZNER_REST_PORT})"
                    return 0
                fi
            fi
        else
            if timeout 5 bash -c "echo >/dev/tcp/${HETZNER_TAILSCALE_IP}/${HETZNER_REST_PORT}" 2>/dev/null; then
                log "Destination TCP port open (no tailscale CLI)"
                return 0
            fi
        fi
        log "Destination not ready (attempt ${attempt}/${MAX_ATTEMPTS}); retry in ${delay}s"
        sleep "${delay}"
        attempt=$((attempt + 1))
        delay=$((delay * 2))
        if [ "${delay}" -gt 600 ]; then
            delay=600
        fi
    done
    log_error "Destination unreachable after ${MAX_ATTEMPTS} attempts"
    exit 3
}

run_restic_copy() {
    local attempt=1
    local delay="${RETRY_BASE_SEC}"
    local -a copy_log
    copy_log="$(mktemp)"

    export RESTIC_FROM_REPOSITORY="${FROM_REPO}"
    export RESTIC_FROM_PASSWORD_FILE="${FROM_PASSWORD_FILE}"
    export RESTIC_REPOSITORY="${TO_REPO}"
    export RESTIC_PASSWORD_FILE="${TO_PASSWORD_FILE}"

    while [ "${attempt}" -le "${MAX_ATTEMPTS}" ]; do
        log "restic copy starting (attempt ${attempt}/${MAX_ATTEMPTS}) host=${BACKUP_HOST}"
        if restic copy --host "${BACKUP_HOST}" 2>&1 | tee "${copy_log}" >&2; then
            if grep -q "skipping snapshot" "${copy_log}"; then
                log "restic copy finished (one or more snapshots skipped as already copied)"
            fi
            if grep -q "snapshot .* saved" "${copy_log}"; then
                log "restic copy finished (new snapshot(s) saved on destination)"
            fi
            if ! grep -qE 'skipping snapshot|snapshot .* saved|copy started' "${copy_log}"; then
                log "restic copy finished (no new snapshots; verify replication metadata)"
            fi
            rm -f "${copy_log}"
            return 0
        fi
        log "restic copy failed (attempt ${attempt}/${MAX_ATTEMPTS}); retry in ${delay}s"
        sleep "${delay}"
        attempt=$((attempt + 1))
        delay=$((delay * 2))
        if [ "${delay}" -gt 600 ]; then
            delay=600
        fi
    done
    rm -f "${copy_log}"
    log_error "restic copy failed after ${MAX_ATTEMPTS} attempts"
    exit 4
}

verify_replication() {
    log "Verifying replication (source id → destination original field)"
    local tmp_py
    tmp_py="$(mktemp)"
    cat > "${tmp_py}" << 'PY'
import json, os, subprocess, sys

backup_host = os.environ["BACKUP_HOST"]
from_repo = os.environ["FROM_REPO"]
from_pw = os.environ["FROM_PASSWORD_FILE"]
to_repo = os.environ["TO_REPO"]
to_pw = os.environ["TO_PASSWORD_FILE"]

def run_snapshots(repo, password_file, extra_env):
    env = os.environ.copy()
    env["RESTIC_REPOSITORY"] = repo
    env["RESTIC_PASSWORD_FILE"] = password_file
    env.update(extra_env)
    proc = subprocess.run(
        ["restic", "snapshots", "--json", "--no-lock", "--host", backup_host],
        env=env,
        capture_output=True,
        text=True,
    )
    if proc.returncode != 0:
        sys.stderr.write(proc.stderr or "restic snapshots failed\n")
        sys.exit(1)
    return json.loads(proc.stdout or "[]")

rest_env = {
    "RESTIC_REST_USERNAME": os.environ["RESTIC_REST_USERNAME"],
    "RESTIC_REST_PASSWORD": os.environ["RESTIC_REST_PASSWORD"],
}
source = run_snapshots(from_repo, from_pw, {})
dest = run_snapshots(to_repo, to_pw, rest_env)

source_ids = {s["id"] for s in source}
dest_originals = {s.get("original") for s in dest if s.get("original")}

missing = sorted(source_ids - dest_originals)
if missing:
    print(f"MISSING_COUNT={len(missing)}")
    for sid in missing:
        print(f"MISSING_SOURCE_ID={sid}")
    sys.exit(1)

print(f"VERIFIED_SOURCE_SNAPSHOTS={len(source_ids)}")
print(f"VERIFIED_DESTINATION_SNAPSHOTS={len(dest)}")
PY

    export BACKUP_HOST FROM_REPO FROM_PASSWORD_FILE TO_REPO TO_PASSWORD_FILE
    local verify_log
    verify_log="$(mktemp)"
    if ! python3 "${tmp_py}" > "${verify_log}" 2>&1; then
        while IFS= read -r vline; do log "${vline}"; done < "${verify_log}"
        rm -f "${tmp_py}" "${verify_log}"
        log_error "Replication verification failed"
        exit 5
    fi
    while IFS= read -r vline; do log "${vline}"; done < "${verify_log}"
    rm -f "${tmp_py}" "${verify_log}"
    log "Replication verification passed"
}

main() {
    log "=== Offsite copy starting ==="
    preflight_config
    load_rest_credentials
    acquire_lock
    wait_for_destination
    run_restic_copy
    verify_replication
    log "=== OFFSITE COPY SUCCESS ==="
}

main "$@"
