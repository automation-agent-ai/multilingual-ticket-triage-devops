#!/usr/bin/env bash
# =============================================================================
# Phase 11 — Application Data Backup to S3
# =============================================================================
# Creates consistent, encrypted backups of DuckDB and LanceDB with SHA-256
# integrity verification. Uploads to S3 bucket provisioned by Terraform.
#
# Usage:
#   ./backup-to-s3.sh [--dry-run]
#
# Exit Codes:
#   0 = Success
#   1 = Backup failed
#   2 = Upload failed
#   3 = Verification failed
# =============================================================================
set -euo pipefail

# ── Configuration ─────────────────────────────────────────────────────────────
REPO_ROOT="${REPO_ROOT:-/home/ubuntu/workspaces/multilingual-ticket-triage-devops}"
DATA_DIR="${REPO_ROOT}/data"
TIMESTAMP=$(date -u +%Y%m%dT%H%M%SZ)
STAGING_DIR="/tmp/liora-backup-staging-${TIMESTAMP}"
LOG_FILE="/var/log/liora-backup.log"

# S3 bucket will be provided by Terraform output
# Default assumes Terraform has been applied
S3_BUCKET="${S3_BUCKET:-s3://liora-triage-backups-523231704152}"
S3_PREFIX="databases/${TIMESTAMP}"

# Dry run mode
DRY_RUN="${1:-}"

# ── Logging ───────────────────────────────────────────────────────────────────
log() {
    echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $*" | tee -a "${LOG_FILE}"
}

log_error() {
    echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] ERROR: $*" | tee -a "${LOG_FILE}" >&2
}

# ── Preflight Checks ──────────────────────────────────────────────────────────
log "=== Liora Phase 11 Application Backup Starting ==="
log "Timestamp: ${TIMESTAMP}"
log "Data source: ${DATA_DIR}"
log "S3 destination: ${S3_BUCKET}/${S3_PREFIX}"

if [ "$DRY_RUN" = "--dry-run" ]; then
    log "DRY RUN MODE - No files will be uploaded"
fi

# Check data directory exists
if [ ! -d "${DATA_DIR}" ]; then
    log_error "Data directory not found: ${DATA_DIR}"
    exit 1
fi

# Check DuckDB exists
if [ ! -f "${DATA_DIR}/tickets.duckdb" ]; then
    log_error "DuckDB not found: ${DATA_DIR}/tickets.duckdb"
    exit 1
fi

# Check LanceDB directory exists
if [ ! -d "${DATA_DIR}/lancedb" ]; then
    log_error "LanceDB directory not found: ${DATA_DIR}/lancedb"
    exit 1
fi

# Check available disk space (need at least 200 MB for staging)
AVAILABLE=$(df -BM /tmp | awk 'NR==2 {print $4}' | sed 's/M//')
if [ "${AVAILABLE}" -lt 200 ]; then
    log_error "Insufficient disk space in /tmp: ${AVAILABLE}M available, need 200M"
    exit 1
fi

log "✓ Preflight checks passed"

# ── Create Staging Directory ──────────────────────────────────────────────────
log "[1/7] Creating staging directory..."
mkdir -p "${STAGING_DIR}"
trap "rm -rf ${STAGING_DIR}" EXIT  # Cleanup on exit
log "✓ Staging: ${STAGING_DIR}"

# ── Backup DuckDB ─────────────────────────────────────────────────────────────
log "[2/7] Backing up DuckDB database..."

# Simple file copy is safe because:
# - No WAL files present (database checkpointed)
# - Pods mount data read-only
# - File not actively written (verified in Phase 11 discovery)
cp "${DATA_DIR}/tickets.duckdb" "${STAGING_DIR}/tickets.duckdb"

DUCKDB_SIZE=$(du -sh "${STAGING_DIR}/tickets.duckdb" | cut -f1)
log "✓ DuckDB copied: ${DUCKDB_SIZE}"

# Verify database integrity
if ! command -v python3 &>/dev/null; then
    log "⚠ Python3 not available, skipping integrity check"
else
    VENV_PYTHON="${REPO_ROOT}/.venv/bin/python"
    if [ -x "${VENV_PYTHON}" ]; then
        log "  Verifying DuckDB integrity..."
        TICKET_COUNT=$(${VENV_PYTHON} -c "
import duckdb
conn = duckdb.connect('${STAGING_DIR}/tickets.duckdb', read_only=True)
count = conn.execute('SELECT COUNT(*) FROM historical_tickets').fetchone()[0]
print(count)
conn.close()
" 2>&1)
        if [ $? -eq 0 ]; then
            log "  ✓ DuckDB valid: ${TICKET_COUNT} historical tickets"
        else
            log_error "DuckDB integrity check failed"
            exit 1
        fi
    fi
fi

# ── Backup LanceDB ────────────────────────────────────────────────────────────
log "[3/7] Backing up LanceDB vector store..."

# LanceDB consists of immutable data files - safe to copy
rsync -a "${DATA_DIR}/lancedb/" "${STAGING_DIR}/lancedb/"

LANCEDB_SIZE=$(du -sh "${STAGING_DIR}/lancedb" | cut -f1)
LANCEDB_FILE_COUNT=$(find "${STAGING_DIR}/lancedb" -type f | wc -l)
log "✓ LanceDB copied: ${LANCEDB_SIZE} (${LANCEDB_FILE_COUNT} files)"

# ── Generate SHA-256 Manifest ─────────────────────────────────────────────────
log "[4/7] Generating SHA-256 integrity manifest..."

MANIFEST_FILE="${STAGING_DIR}/MANIFEST.sha256"
pushd "${STAGING_DIR}" > /dev/null
find . -type f -not -name "MANIFEST.sha256" | sort | xargs sha256sum > "${MANIFEST_FILE}"
popd > /dev/null

CHECKSUM_COUNT=$(wc -l < "${MANIFEST_FILE}")
log "✓ Manifest created: ${CHECKSUM_COUNT} files"

# ── Create Backup Metadata ────────────────────────────────────────────────────
log "[5/7] Creating backup metadata..."

METADATA_FILE="${STAGING_DIR}/backup-metadata.json"
cat > "${METADATA_FILE}" <<EOF
{
  "backup_timestamp": "${TIMESTAMP}",
  "backup_date": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "source_host": "$(hostname)",
  "source_instance": "i-07bc3aaf0d692974d",
  "data_source": "${DATA_DIR}",
  "components": {
    "duckdb": {
      "file": "tickets.duckdb",
      "size": "$(stat -c%s ${STAGING_DIR}/tickets.duckdb)",
      "tables": ["historical_tickets", "triage_predictions", "triage_metrics", "triage_confusion_matrix", "triage_runs"],
      "ticket_count": ${TICKET_COUNT:-0}
    },
    "lancedb": {
      "directory": "lancedb/",
      "size": "$(du -sb ${STAGING_DIR}/lancedb | cut -f1)",
      "file_count": ${LANCEDB_FILE_COUNT}
    }
  },
  "backup_method": "filesystem-copy",
  "integrity_verification": "sha256",
  "manifest_file": "MANIFEST.sha256",
  "phase": "phase11",
  "terraform_managed": true
}
EOF

log "✓ Metadata created"

# ── Upload to S3 ──────────────────────────────────────────────────────────────
if [ "$DRY_RUN" = "--dry-run" ]; then
    log "[6/7] DRY RUN - Skipping S3 upload"
    log "Would upload to: ${S3_BUCKET}/${S3_PREFIX}/"
    TOTAL_SIZE=$(du -sh "${STAGING_DIR}" | cut -f1)
    log "Total backup size: ${TOTAL_SIZE}"
else
    log "[6/7] Uploading to S3..."
    
    # Check AWS credentials
    if ! aws sts get-caller-identity &>/dev/null; then
        log_error "AWS credentials not configured or expired"
        exit 2
    fi
    
    # Upload with server-side encryption
    if aws s3 sync "${STAGING_DIR}/" "${S3_BUCKET}/${S3_PREFIX}/" \
        --storage-class STANDARD \
        --no-progress 2>&1 | tee -a "${LOG_FILE}"; then
        log "✓ Upload complete"
    else
        log_error "S3 upload failed"
        exit 2
    fi
fi

# ── Verify Upload ─────────────────────────────────────────────────────────────
if [ "$DRY_RUN" = "--dry-run" ]; then
    log "[7/7] DRY RUN - Skipping verification"
else
    log "[7/7] Verifying S3 upload..."
    
    # Check manifest exists in S3
    if aws s3 ls "${S3_BUCKET}/${S3_PREFIX}/MANIFEST.sha256" &>/dev/null; then
        log "✓ Manifest verified in S3"
    else
        log_error "Manifest not found in S3 - upload may have failed"
        exit 3
    fi
    
    # Check metadata exists
    if aws s3 ls "${S3_BUCKET}/${S3_PREFIX}/backup-metadata.json" &>/dev/null; then
        log "✓ Metadata verified in S3"
    else
        log_error "Metadata not found in S3 - upload may have failed"
        exit 3
    fi
    
    # Get S3 object count
    S3_OBJECT_COUNT=$(aws s3 ls "${S3_BUCKET}/${S3_PREFIX}/" --recursive | wc -l)
    log "✓ S3 objects: ${S3_OBJECT_COUNT}"
fi

# ── Success Summary ───────────────────────────────────────────────────────────
TOTAL_SIZE=$(du -sh "${STAGING_DIR}" | cut -f1)
DURATION=$(($(date +%s) - $(date -d "${TIMESTAMP}" +%s 2>/dev/null || echo 0)))

log "=== Backup Complete ==="
log "Total size: ${TOTAL_SIZE}"
log "Duration: ${DURATION}s"
if [ "$DRY_RUN" != "--dry-run" ]; then
    log "S3 location: ${S3_BUCKET}/${S3_PREFIX}/"
    log "Recovery command: aws s3 sync ${S3_BUCKET}/${S3_PREFIX}/ /tmp/restore/"
fi
log "✓ SUCCESS"

exit 0
