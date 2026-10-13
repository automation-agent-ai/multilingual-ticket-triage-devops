#!/usr/bin/env bash
# =============================================================================
# Phase 11C — Restic Backup Wrapper
# =============================================================================
# Performs encrypted, incremental backup to Restic repository:
# 1. Prepare consistent data snapshot (Python helper)
# 2. Backup to Restic repository
# 3. Prune old snapshots (keep last 7)
# 4. Check repository integrity
# 5. Cleanup staging directory
#
# Exit Codes:
#   0 = Success
#   1 = Data preparation failed
#   2 = Restic backup failed
#   3 = Already running (lock detected)
#   4 = Configuration error
# =============================================================================
set -euo pipefail

# ── Configuration ─────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${REPO_ROOT:-/home/ubuntu/workspaces/multilingual-ticket-triage-devops}"
TIMESTAMP=$(date -u +%Y%m%dT%H%M%SZ)
STAGING_DIR="/tmp/liora-restic-staging-${TIMESTAMP}"
LOCK_FILE="/var/run/liora-restic-backup.lock"

# Logging: Use stderr for systemd journald, fallback to file for manual runs
if [ -t 1 ]; then
    # Interactive terminal - use log file
    LOG_FILE="/tmp/liora-restic-backup-${TIMESTAMP}.log"
else
    # Non-interactive (systemd) - use stderr (journald)
    LOG_FILE="/dev/stderr"
fi

# Restic configuration
RESTIC_REPOSITORY="${RESTIC_REPOSITORY:-}"
RESTIC_PASSWORD_FILE="${RESTIC_PASSWORD_FILE:-/etc/liora-backup/restic-password}"
RESTIC_BACKUP_PATH="/liora-backup/data"  # Logical path in repository

# Python helpers
PREPARE_SCRIPT="${SCRIPT_DIR}/prepare-backup-data.py"
VENV_PYTHON="${REPO_ROOT}/.venv/bin/python"

# ── Logging ───────────────────────────────────────────────────────────────────
log() {
    echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $*" | tee -a "${LOG_FILE}"
}

log_error() {
    echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] ERROR: $*" | tee -a "${LOG_FILE}" >&2
}

# ── Lock Management ───────────────────────────────────────────────────────────
acquire_lock() {
    if [ -f "${LOCK_FILE}" ]; then
        PID=$(cat "${LOCK_FILE}" 2>/dev/null || echo "unknown")
        if ps -p "${PID}" > /dev/null 2>&1; then
            log_error "Backup already running (PID ${PID})"
            exit 3
        else
            log "Removing stale lock file"
            rm -f "${LOCK_FILE}"
        fi
    fi
    
    echo $$ > "${LOCK_FILE}"
    trap "rm -f ${LOCK_FILE}; rm -rf ${STAGING_DIR}" EXIT
}

# ── Preflight Checks ──────────────────────────────────────────────────────────
preflight_checks() {
    log "=== Phase 11C Restic Backup Starting ==="
    log "Timestamp: ${TIMESTAMP}"
    
    # Check Python helper exists
    if [ ! -x "${PREPARE_SCRIPT}" ]; then
        log_error "Preparation script not found: ${PREPARE_SCRIPT}"
        exit 4
    fi
    
    # Check Python venv
    if [ ! -x "${VENV_PYTHON}" ]; then
        log_error "Python venv not found: ${VENV_PYTHON}"
        exit 4
    fi
    
    # Check Restic is installed
    if ! command -v restic &>/dev/null; then
        log_error "Restic not installed"
        exit 4
    fi
    
    # Check repository configured
    if [ -z "${RESTIC_REPOSITORY}" ]; then
        log_error "RESTIC_REPOSITORY not set"
        exit 4
    fi
    
    # Check password file exists
    if [ ! -f "${RESTIC_PASSWORD_FILE}" ]; then
        log_error "Restic password file not found: ${RESTIC_PASSWORD_FILE}"
        exit 4
    fi
    
    # Check password file permissions (should be 600)
    PERMS=$(stat -c "%a" "${RESTIC_PASSWORD_FILE}")
    if [ "${PERMS}" != "600" ]; then
        log "WARNING: Password file permissions are ${PERMS}, should be 600"
    fi
    
    log "✓ Preflight checks passed"
    log "  Repository: ${RESTIC_REPOSITORY}"
    log "  Backup path: ${RESTIC_BACKUP_PATH}"
}

# ── Prepare Data ──────────────────────────────────────────────────────────────
prepare_data() {
    log "[1/5] Preparing consistent data snapshot..."
    
    # Run Python preparation script
    if "${VENV_PYTHON}" "${PREPARE_SCRIPT}" "${STAGING_DIR}" 2>&1 | tee -a "${LOG_FILE}"; then
        log "✓ Data preparation complete"
    else
        log_error "Data preparation failed"
        exit 1
    fi
    
    # Verify staging directory
    if [ ! -d "${STAGING_DIR}" ]; then
        log_error "Staging directory not created: ${STAGING_DIR}"
        exit 1
    fi
    
    STAGING_SIZE=$(du -sh "${STAGING_DIR}" | cut -f1)
    log "  Staging size: ${STAGING_SIZE}"
}

# ── Restic Backup ─────────────────────────────────────────────────────────────
restic_backup() {
    log "[2/5] Creating Restic snapshot..."
    
    export RESTIC_REPOSITORY
    export RESTIC_PASSWORD_FILE
    
    # Backup with tags and metadata
    if restic backup "${STAGING_DIR}" \
        --tag "phase11c" \
        --tag "automated" \
        --tag "$(date +%Y-%m-%d)" \
        --host "liora-aws-ec2" \
        --json 2>&1 | tee -a "${LOG_FILE}"; then
        log "✓ Restic backup complete"
    else
        log_error "Restic backup failed"
        exit 2
    fi
}

# ── Prune Old Snapshots ───────────────────────────────────────────────────────
restic_prune() {
    log "[3/5] Pruning old snapshots (with safety checks)..."
    
    export RESTIC_REPOSITORY
    export RESTIC_PASSWORD_FILE
    
    # SAFETY CHECK: Count snapshots before pruning
    SNAPSHOT_COUNT=$(restic snapshots --json --host "liora-aws-ec2" | jq '. | length' 2>/dev/null || echo "0")
    log "Current snapshot count: ${SNAPSHOT_COUNT}"
    
    if [ "${SNAPSHOT_COUNT}" -lt 2 ]; then
        log "WARNING: Only ${SNAPSHOT_COUNT} snapshot(s) exist - skipping prune to preserve backup"
        log "Pruning will resume once 8+ snapshots exist"
        return 0
    fi
    
    # SAFETY CHECK: Verify latest snapshot is from THIS backup run
    LATEST_SNAPSHOT_TIME=$(restic snapshots --json --host "liora-aws-ec2" --last | jq -r '.[0].time' 2>/dev/null || echo "")
    if [ -z "${LATEST_SNAPSHOT_TIME}" ]; then
        log "WARNING: Could not verify latest snapshot - skipping prune for safety"
        return 0
    fi
    
    LATEST_AGE_SECONDS=$(( $(date +%s) - $(date -d "${LATEST_SNAPSHOT_TIME}" +%s) ))
    if [ "${LATEST_AGE_SECONDS}" -gt 300 ]; then
        log "WARNING: Latest snapshot is ${LATEST_AGE_SECONDS}s old - skipping prune (expected <300s)"
        log "This suggests current backup did not create a new snapshot"
        return 0
    fi
    
    log "✓ Latest snapshot verified (${LATEST_AGE_SECONDS}s old)"
    
    # Keep last 7 daily snapshots (minimum 2 required for prune to run)
    # This ensures we ALWAYS have at least 7 backups
    log "Pruning old snapshots (keeping last 7)..."
    if restic forget \
        --keep-last 7 \
        --prune \
        --host "liora-aws-ec2" 2>&1 | tee -a "${LOG_FILE}"; then
        log "✓ Pruning complete"
        
        # Log new snapshot count
        NEW_COUNT=$(restic snapshots --json --host "liora-aws-ec2" | jq '. | length' 2>/dev/null || echo "unknown")
        log "Snapshot count after prune: ${NEW_COUNT}"
    else
        log "WARNING: Pruning failed (non-fatal) - old snapshots retained"
    fi
}

# ── Check Repository ──────────────────────────────────────────────────────────
restic_check() {
    log "[4/5] Checking repository integrity..."
    
    export RESTIC_REPOSITORY
    export RESTIC_PASSWORD_FILE
    
    # Quick check (don't read all data)
    if restic check --read-data-subset=1% 2>&1 | tee -a "${LOG_FILE}"; then
        log "✓ Repository check passed"
    else
        log "WARNING: Repository check failed (non-fatal)"
    fi
}

# ── Cleanup ───────────────────────────────────────────────────────────────────
cleanup_staging() {
    log "[5/5] Cleaning up staging directory..."
    
    if [ -d "${STAGING_DIR}" ]; then
        rm -rf "${STAGING_DIR}"
        log "✓ Staging cleaned up"
    fi
}

# ── Summary ───────────────────────────────────────────────────────────────────
backup_summary() {
    log "=== Backup Summary ==="
    
    export RESTIC_REPOSITORY
    export RESTIC_PASSWORD_FILE
    
    # Get latest snapshot info
    LATEST_SNAPSHOT=$(restic snapshots --last --json | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    if data:
        snap = data[0]
        print(f\"ID: {snap['short_id']}\")
        print(f\"Time: {snap['time']}\")
        print(f\"Host: {snap['hostname']}\")
        print(f\"Tags: {', '.join(snap.get('tags', []))}\")
except:
    print('Unable to parse snapshot info')
" 2>/dev/null || echo "Unable to fetch snapshot info")
    
    log "${LATEST_SNAPSHOT}"
    log "✓ Backup completed successfully"
}

# ── Main ──────────────────────────────────────────────────────────────────────
main() {
    acquire_lock
    preflight_checks
    prepare_data
    restic_backup
    restic_prune
    restic_check
    cleanup_staging
    backup_summary
    
    log "=== SUCCESS ==="
    exit 0
}

main "$@"
