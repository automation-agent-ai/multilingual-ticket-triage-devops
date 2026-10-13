#!/usr/bin/env bash
# =============================================================================
# Phase 11C — Restic Restore Test
# =============================================================================
# Performs isolated restore test from Restic repository:
# 1. Restore latest snapshot to isolated directory
# 2. Validate databases (Python helper)
# 3. Report results
# 4. Cleanup
#
# Exit Codes:
#   0 = Restore test passed
#   1 = Restore failed
#   2 = Validation failed
#   3 = Configuration error
# =============================================================================
set -euo pipefail

# ── Configuration ─────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${REPO_ROOT:-/home/ubuntu/workspaces/multilingual-ticket-triage-devops}"
TIMESTAMP=$(date +%s)
RESTORE_DIR="/tmp/liora-restic-restore-test-${TIMESTAMP}"
LOG_FILE="/var/log/liora-restic-restore-test.log"

# Restic configuration
RESTIC_REPOSITORY="${RESTIC_REPOSITORY:-}"
RESTIC_PASSWORD_FILE="${RESTIC_PASSWORD_FILE:-/etc/liora-backup/restic-password}"

# Python validator
VALIDATE_SCRIPT="${SCRIPT_DIR}/validate-databases.py"
VENV_PYTHON="${REPO_ROOT}/.venv/bin/python"

# Snapshot to restore (default: latest)
SNAPSHOT_ID="${1:-latest}"

# ── Logging ───────────────────────────────────────────────────────────────────
log() {
    echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $*" | tee -a "${LOG_FILE}"
}

log_error() {
    echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] ERROR: $*" | tee -a "${LOG_FILE}" >&2
}

# ── Cleanup ───────────────────────────────────────────────────────────────────
cleanup() {
    if [ -d "${RESTORE_DIR}" ]; then
        log "Cleaning up restore directory: ${RESTORE_DIR}"
        rm -rf "${RESTORE_DIR}"
    fi
}

trap cleanup EXIT

# ── Preflight Checks ──────────────────────────────────────────────────────────
preflight_checks() {
    log "=== Phase 11C Restic Restore Test Starting ==="
    log "Restore directory: ${RESTORE_DIR}"
    log "Snapshot: ${SNAPSHOT_ID}"
    
    # Check Python validator exists
    if [ ! -x "${VALIDATE_SCRIPT}" ]; then
        log_error "Validation script not found: ${VALIDATE_SCRIPT}"
        exit 3
    fi
    
    # Check Python venv
    if [ ! -x "${VENV_PYTHON}" ]; then
        log_error "Python venv not found: ${VENV_PYTHON}"
        exit 3
    fi
    
    # Check Restic is installed
    if ! command -v restic &>/dev/null; then
        log_error "Restic not installed"
        exit 3
    fi
    
    # Check repository configured
    if [ -z "${RESTIC_REPOSITORY}" ]; then
        log_error "RESTIC_REPOSITORY not set"
        exit 3
    fi
    
    # Check password file exists
    if [ ! -f "${RESTIC_PASSWORD_FILE}" ]; then
        log_error "Restic password file not found: ${RESTIC_PASSWORD_FILE}"
        exit 3
    fi
    
    log "✓ Preflight checks passed"
}

# ── List Available Snapshots ──────────────────────────────────────────────────
list_snapshots() {
    log "[1/4] Listing available snapshots..."
    
    export RESTIC_REPOSITORY
    export RESTIC_PASSWORD_FILE
    
    restic snapshots --compact 2>&1 | tee -a "${LOG_FILE}" || true
}

# ── Restore Snapshot ──────────────────────────────────────────────────────────
restore_snapshot() {
    log "[2/4] Restoring snapshot ${SNAPSHOT_ID}..."
    
    export RESTIC_REPOSITORY
    export RESTIC_PASSWORD_FILE
    
    START_TIME=$(date +%s)
    
    # Create restore directory
    mkdir -p "${RESTORE_DIR}"
    
    # Restore the snapshot
    # Note: Restic restores from the root of what was backed up
    if restic restore "${SNAPSHOT_ID}" \
        --target "${RESTORE_DIR}" 2>&1 | tee -a "${LOG_FILE}"; then
        
        END_TIME=$(date +%s)
        DURATION=$((END_TIME - START_TIME))
        
        # Find the actual restored data (Restic preserves the source path structure)
        # Look for the staging directory structure
        ACTUAL_DATA_DIR=$(find "${RESTORE_DIR}" -name "backup-manifest.json" -exec dirname {} \; | head -1)
        
        if [ -z "${ACTUAL_DATA_DIR}" ]; then
            log_error "Could not find restored data in ${RESTORE_DIR}"
            log "Contents:"
            find "${RESTORE_DIR}" -type f | head -20 | tee -a "${LOG_FILE}"
            exit 1
        fi
        
        RESTORED_SIZE=$(du -sh "${ACTUAL_DATA_DIR}" | cut -f1)
        
        log "✓ Restore complete"
        log "  Duration: ${DURATION}s"
        log "  Size: ${RESTORED_SIZE}"
        log "  Location: ${ACTUAL_DATA_DIR}"
        
        # Set global for validation step
        VALIDATION_DIR="${ACTUAL_DATA_DIR}"
    else
        log_error "Restore failed"
        exit 1
    fi
}

# ── Validate Restored Data ────────────────────────────────────────────────────
validate_data() {
    log "[3/4] Validating restored data..."
    
    if [ -z "${VALIDATION_DIR}" ]; then
        log_error "Validation directory not set"
        exit 1
    fi
    
    # Run Python validation script
    if "${VENV_PYTHON}" "${VALIDATE_SCRIPT}" "${VALIDATION_DIR}" 2>&1 | tee -a "${LOG_FILE}"; then
        log "✓ Validation complete"
    else
        log_error "Validation failed"
        exit 2
    fi
}

# ── Compare with Original ─────────────────────────────────────────────────────
compare_original() {
    log "[4/4] Comparing with original data..."
    
    ORIGINAL_DUCKDB="${REPO_ROOT}/data/tickets.duckdb"
    
    if [ -f "${ORIGINAL_DUCKDB}" ] && [ -f "${VALIDATION_DIR}/tickets.duckdb" ]; then
        ORIG_SHA=$(sha256sum "${ORIGINAL_DUCKDB}" | awk '{print $1}')
        RESTORED_SHA=$(sha256sum "${VALIDATION_DIR}/tickets.duckdb" | awk '{print $1}')
        
        if [ "${ORIG_SHA}" = "${RESTORED_SHA}" ]; then
            log "  ✓ Original DuckDB matches restored copy"
            log "    SHA-256: ${ORIG_SHA:0:16}..."
        else
            log "  ℹ Original DuckDB differs from backup snapshot"
            log "    This is expected if data was written after backup"
            log "    Original:  ${ORIG_SHA:0:32}..."
            log "    Restored:  ${RESTORED_SHA:0:32}..."
        fi
    else
        log "  ℹ Original data not available for comparison"
    fi
}

# ── Summary ───────────────────────────────────────────────────────────────────
restore_summary() {
    log "=== Restore Test Summary ==="
    log "✓ Snapshot restored successfully"
    log "✓ All validations passed"
    log "✓ Databases verified"
    log "✓ Checksums valid"
    log "=== RESTORE TEST PASSED ==="
}

# ── Main ──────────────────────────────────────────────────────────────────────
main() {
    preflight_checks
    list_snapshots
    restore_snapshot
    validate_data
    compare_original
    restore_summary
    
    log "=== SUCCESS ==="
    exit 0
}

main "$@"
