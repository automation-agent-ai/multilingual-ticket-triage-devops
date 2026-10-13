#!/usr/bin/env bash
# =============================================================================
# Phase 11 — Isolated Restore Test
# =============================================================================
# Downloads backup from S3 to isolated directory and verifies:
#   1. SHA-256 checksums match
#   2. DuckDB opens and contains expected data
#   3. LanceDB opens and contains expected vectors
#   4. Original source files unchanged
#
# Usage:
#   ./restore-test.sh <S3-backup-path>
#   ./restore-test.sh s3://bucket/databases/20261013T020000Z/
#
# Exit Codes:
#   0 = Restore test passed
#   1 = Download failed
#   2 = Checksum verification failed
#   3 = DuckDB verification failed
#   4 = LanceDB verification failed
# =============================================================================
set -euo pipefail

# ── Configuration ─────────────────────────────────────────────────────────────
S3_BACKUP_PATH="${1:-}"
REPO_ROOT="${REPO_ROOT:-/home/ubuntu/workspaces/multilingual-ticket-triage-devops}"
VENV_PYTHON="${REPO_ROOT}/.venv/bin/python"
RESTORE_DIR="/tmp/phase11-restore-test-$(date +%s)"
LOG_FILE="/var/log/liora-restore-test.log"

# Expected values (from Phase 11 discovery)
EXPECTED_TICKETS=4000
EXPECTED_VECTORS=3206
EXPECTED_TABLES=5

# ── Logging ───────────────────────────────────────────────────────────────────
log() {
    echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $*" | tee -a "${LOG_FILE}"
}

log_error() {
    echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] ERROR: $*" | tee -a "${LOG_FILE}" >&2
}

# ── Argument Validation ───────────────────────────────────────────────────────
if [ -z "${S3_BACKUP_PATH}" ]; then
    echo "Usage: $0 <S3-backup-path>"
    echo "Example: $0 s3://liora-triage-backups-523231704152/databases/20261013T020000Z/"
    exit 1
fi

# Remove trailing slash if present
S3_BACKUP_PATH="${S3_BACKUP_PATH%/}"

log "=== Liora Phase 11 Isolated Restore Test ==="
log "Source: ${S3_BACKUP_PATH}"
log "Destination: ${RESTORE_DIR}"
log "Start time: $(date -u +%Y-%m-%dT%H:%M:%SZ)"

START_TIME=$(date +%s)

# ── Create Restore Directory ──────────────────────────────────────────────────
log "[1/6] Creating isolated restore directory..."
mkdir -p "${RESTORE_DIR}"
trap "log 'Cleaning up ${RESTORE_DIR}'; rm -rf ${RESTORE_DIR}" EXIT

# ── Download from S3 ──────────────────────────────────────────────────────────
log "[2/6] Downloading backup from S3..."

if ! aws s3 sync "${S3_BACKUP_PATH}/" "${RESTORE_DIR}/" 2>&1 | tee -a "${LOG_FILE}"; then
    log_error "S3 download failed"
    exit 1
fi

DOWNLOAD_SIZE=$(du -sh "${RESTORE_DIR}" | cut -f1)
log "✓ Downloaded: ${DOWNLOAD_SIZE}"

# ── Verify SHA-256 Checksums ──────────────────────────────────────────────────
log "[3/6] Verifying SHA-256 checksums..."

if [ ! -f "${RESTORE_DIR}/MANIFEST.sha256" ]; then
    log_error "Manifest file not found in backup"
    exit 2
fi

pushd "${RESTORE_DIR}" > /dev/null

# Verify all files except the manifest itself
if grep -v "^\S\+  \./MANIFEST\.sha256$" MANIFEST.sha256 | sha256sum --quiet -c - 2>&1 | tee -a "${LOG_FILE}"; then
    log "✓ All checksums verified"
else
    log_error "Checksum verification failed - backup may be corrupted"
    popd > /dev/null
    exit 2
fi

popd > /dev/null

# ── Verify DuckDB Database ────────────────────────────────────────────────────
log "[4/6] Verifying DuckDB database..."

if [ ! -f "${RESTORE_DIR}/tickets.duckdb" ]; then
    log_error "DuckDB file not found in backup"
    exit 3
fi

if [ ! -x "${VENV_PYTHON}" ]; then
    log_error "Python venv not found: ${VENV_PYTHON}"
    exit 3
fi

# Verify database structure and data
VERIFY_RESULT=$(${VENV_PYTHON} - <<PYEOF
import duckdb
import sys

try:
    conn = duckdb.connect('${RESTORE_DIR}/tickets.duckdb', read_only=True)
    
    # Get tables
    tables = [t[0] for t in conn.execute('SHOW TABLES').fetchall()]
    print(f'Tables: {len(tables)}')
    
    if len(tables) != ${EXPECTED_TABLES}:
        print(f'ERROR: Expected ${EXPECTED_TABLES} tables, found {len(tables)}')
        sys.exit(1)
    
    # Check historical_tickets
    ticket_count = conn.execute('SELECT COUNT(*) FROM historical_tickets').fetchone()[0]
    print(f'Tickets: {ticket_count}')
    
    if ticket_count < ${EXPECTED_TICKETS}:
        print(f'ERROR: Expected at least ${EXPECTED_TICKETS} tickets, found {ticket_count}')
        sys.exit(1)
    
    # Check all tables
    for table in tables:
        count = conn.execute(f'SELECT COUNT(*) FROM {table}').fetchone()[0]
        print(f'{table}: {count} rows')
    
    conn.close()
    sys.exit(0)
    
except Exception as e:
    print(f'ERROR: {e}')
    sys.exit(1)
PYEOF
)

if [ $? -eq 0 ]; then
    log "✓ DuckDB verification passed:"
    echo "$VERIFY_RESULT" | while read -r line; do
        log "  ${line}"
    done
else
    log_error "DuckDB verification failed:"
    echo "$VERIFY_RESULT" | while read -r line; do
        log_error "  ${line}"
    done
    exit 3
fi

# ── Verify LanceDB Vector Store ───────────────────────────────────────────────
log "[5/6] Verifying LanceDB vector store..."

if [ ! -d "${RESTORE_DIR}/lancedb" ]; then
    log_error "LanceDB directory not found in backup"
    exit 4
fi

LANCE_RESULT=$(${VENV_PYTHON} - <<PYEOF2
import lancedb
import sys

try:
    db = lancedb.connect('${RESTORE_DIR}/lancedb')
    tbl = db.open_table('ticket_embeddings')
    count = tbl.count_rows()
    
    print(f'Vectors: {count}')
    
    if count != ${EXPECTED_VECTORS}:
        print(f'ERROR: Expected ${EXPECTED_VECTORS} vectors, found {count}')
        sys.exit(1)
    
    # Get schema info
    schema = tbl.schema
    print(f'Schema: {len(schema)} fields')
    
    sys.exit(0)
    
except Exception as e:
    print(f'ERROR: {e}')
    sys.exit(1)
PYEOF2
)

if [ $? -eq 0 ]; then
    log "✓ LanceDB verification passed:"
    echo "$LANCE_RESULT" | while read -r line; do
        log "  ${line}"
    done
else
    log_error "LanceDB verification failed:"
    echo "$LANCE_RESULT" | while read -r line; do
        log_error "  ${line}"
    done
    exit 4
fi

# ── Verify Original Data Unchanged ────────────────────────────────────────────
log "[6/6] Verifying original data unchanged..."

ORIGINAL_DUCKDB="${REPO_ROOT}/data/tickets.duckdb"

if [ -f "${ORIGINAL_DUCKDB}" ]; then
    ORIG_SHA=$(sha256sum "${ORIGINAL_DUCKDB}" | awk '{print $1}')
    BACKUP_SHA=$(sha256sum "${RESTORE_DIR}/tickets.duckdb" | awk '{print $1}')
    
    if [ "${ORIG_SHA}" = "${BACKUP_SHA}" ]; then
        log "✓ Original DuckDB unchanged (SHA-256: ${ORIG_SHA:0:16}...)"
    else
        log "⚠ Original DuckDB differs from backup snapshot"
        log "  This is acceptable if data was written after backup"
        log "  Original: ${ORIG_SHA:0:32}..."
        log "  Backup:   ${BACKUP_SHA:0:32}..."
    fi
else
    log "⚠ Original DuckDB not found (may be running on different system)"
fi

# ── Success Summary ───────────────────────────────────────────────────────────
END_TIME=$(date +%s)
DURATION=$((END_TIME - START_TIME))

log "=== Restore Test Complete ==="
log "Duration: ${DURATION}s"
log "Restored size: ${DOWNLOAD_SIZE}"
log "DuckDB: ${EXPECTED_TABLES} tables verified"
log "LanceDB: ${EXPECTED_VECTORS} vectors verified"
log "SHA-256: All files verified"
log "✓ RESTORE TEST PASSED"

# Note: Cleanup happens via trap on EXIT

exit 0
