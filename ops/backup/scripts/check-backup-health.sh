#!/usr/bin/env bash
# =============================================================================
# Phase 11C — Restic Health Check
# =============================================================================
# Checks backup health:
# 1. Repository accessibility
# 2. Latest snapshot age
# 3. Snapshot count
# 4. Repository integrity
#
# Exit Codes:
#   0 = Healthy
#   1 = Warning (backup aging)
#   2 = Critical (backup too old or missing)
# =============================================================================
set -euo pipefail

# Configuration
RESTIC_REPOSITORY="${RESTIC_REPOSITORY:-}"
RESTIC_PASSWORD_FILE="${RESTIC_PASSWORD_FILE:-/etc/liora-backup/restic-password}"
MAX_AGE_HOURS=48
WARN_AGE_HOURS=30
MIN_SNAPSHOTS=1

# Logging
log() {
    echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $*"
}

# Check configuration
if [ -z "${RESTIC_REPOSITORY}" ]; then
    log "✗ CRITICAL: RESTIC_REPOSITORY not set"
    exit 2
fi

if [ ! -f "${RESTIC_PASSWORD_FILE}" ]; then
    log "✗ CRITICAL: Password file not found: ${RESTIC_PASSWORD_FILE}"
    exit 2
fi

export RESTIC_REPOSITORY
export RESTIC_PASSWORD_FILE

log "Checking Restic backup health..."
log "Repository: ${RESTIC_REPOSITORY}"

# Check repository accessibility
if ! restic snapshots --last --json &>/dev/null; then
    log "✗ CRITICAL: Cannot access Restic repository"
    exit 2
fi

log "✓ Repository accessible"

# Get latest snapshot
LATEST_JSON=$(restic snapshots --last --json 2>/dev/null)

if [ -z "${LATEST_JSON}" ] || [ "${LATEST_JSON}" = "null" ] || [ "${LATEST_JSON}" = "[]" ]; then
    log "✗ CRITICAL: No snapshots found in repository"
    exit 2
fi

# Parse latest snapshot time
LATEST_TIME=$(echo "${LATEST_JSON}" | python3 -c "
import sys, json
from datetime import datetime
try:
    data = json.load(sys.stdin)
    if data:
        time_str = data[0]['time']
        # Parse ISO 8601 timestamp
        dt = datetime.fromisoformat(time_str.replace('Z', '+00:00'))
        print(int(dt.timestamp()))
    else:
        print('0')
except:
    print('0')
")

if [ "${LATEST_TIME}" = "0" ]; then
    log "✗ CRITICAL: Could not parse snapshot timestamp"
    exit 2
fi

# Calculate age
NOW=$(date +%s)
AGE_SECONDS=$((NOW - LATEST_TIME))
AGE_HOURS=$((AGE_SECONDS / 3600))

log "Latest snapshot: ${AGE_HOURS} hours old"

# Check age thresholds
if [ ${AGE_HOURS} -gt ${MAX_AGE_HOURS} ]; then
    log "✗ CRITICAL: Backup is ${AGE_HOURS} hours old (max: ${MAX_AGE_HOURS})"
    exit 2
elif [ ${AGE_HOURS} -gt ${WARN_AGE_HOURS} ]; then
    log "⚠ WARNING: Backup is ${AGE_HOURS} hours old (warn: ${WARN_AGE_HOURS})"
    exit 1
fi

log "✓ Backup age OK (${AGE_HOURS} hours)"

# Check snapshot count
SNAPSHOT_COUNT=$(restic snapshots --json 2>/dev/null | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    print(len(data))
except:
    print('0')
")

if [ "${SNAPSHOT_COUNT}" = "0" ]; then
    log "✗ CRITICAL: No snapshots in repository"
    exit 2
fi

log "✓ Snapshot count: ${SNAPSHOT_COUNT}"

# Quick integrity check (optional, can be slow)
# Uncomment to enable:
# log "Running quick integrity check..."
# if restic check --read-data-subset=1% &>/dev/null; then
#     log "✓ Repository integrity OK"
# else
#     log "⚠ WARNING: Repository integrity check failed"
#     exit 1
# fi

log "=== Backup Health: OK ==="
exit 0
