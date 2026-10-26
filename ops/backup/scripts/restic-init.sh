#!/usr/bin/env bash
# =============================================================================
# Phase 11C — Restic Repository Initialization
# =============================================================================
# One-time initialization of Restic repository.
# Run this once after Terraform provisions the S3 bucket.
#
# Usage:
#   ./restic-init.sh
#
# Environment variables required:
#   RESTIC_REPOSITORY - Repository URL (e.g., s3:s3.amazonaws.com/bucket-name)
#   RESTIC_PASSWORD_FILE - Path to password file
# =============================================================================
set -euo pipefail

# Configuration
RESTIC_REPOSITORY="${RESTIC_REPOSITORY:-}"
RESTIC_PASSWORD_FILE="${RESTIC_PASSWORD_FILE:-/etc/liora-backup/restic-password}"

log() {
    echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $*"
}

log_error() {
    echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] ERROR: $*" >&2
}

log "=== Restic Repository Initialization ==="

# Check configuration
if [ -z "${RESTIC_REPOSITORY}" ]; then
    log_error "RESTIC_REPOSITORY not set"
    log "Example: export RESTIC_REPOSITORY='s3:s3.amazonaws.com/liora-triage-backups-523231704152'"
    exit 1
fi

if [ ! -f "${RESTIC_PASSWORD_FILE}" ]; then
    log_error "Password file not found: ${RESTIC_PASSWORD_FILE}"
    log "Create it first with: echo 'your-secure-password' > ${RESTIC_PASSWORD_FILE} && chmod 600 ${RESTIC_PASSWORD_FILE}"
    exit 1
fi

export RESTIC_REPOSITORY
export RESTIC_PASSWORD_FILE

log "Repository: ${RESTIC_REPOSITORY}"
log "Password file: ${RESTIC_PASSWORD_FILE}"

# Check if already initialized
if restic snapshots &>/dev/null; then
    log "Repository already initialized"
    log "Snapshot count: $(restic snapshots --json | python3 -c 'import sys, json; print(len(json.load(sys.stdin)))')"
    exit 0
fi

# Initialize repository
log "Initializing new Restic repository..."

if restic init; then
    log "✓ Repository initialized successfully"
    log "You can now run backups"
else
    log_error "Repository initialization failed"
    exit 1
fi

# Verify
if restic snapshots &>/dev/null; then
    log "✓ Repository verification passed"
else
    log_error "Repository verification failed"
    exit 1
fi

log "=== Initialization Complete ==="
exit 0
