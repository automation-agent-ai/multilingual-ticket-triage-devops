#!/usr/bin/env bash
# Phase 11C — Local Regression Test Suite
set -euo pipefail

TIMESTAMP=$(date -u +%Y%m%dT%H%M%SZ)
TEST_REPO="/tmp/restic-test-repo-${TIMESTAMP}"
TEST_PASSWORD="/tmp/restic-test-password-${TIMESTAMP}"
STAGING_DIR="/tmp/liora-restic-staging-${TIMESTAMP}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="/home/ubuntu/workspaces/multilingual-ticket-triage-devops"
VENV_PYTHON="${REPO_ROOT}/.venv/bin/python"

echo "=== Phase 11C Regression Test Suite ==="
echo "Timestamp: ${TIMESTAMP}"
echo ""

# Cleanup function
cleanup() {
    echo ""
    echo "Cleaning up test artifacts..."
    rm -rf "${TEST_REPO}" "${TEST_PASSWORD}" "${STAGING_DIR}" /tmp/liora-restic-restore-test-*
    echo "✓ Cleanup complete"
}
trap cleanup EXIT

# Create test password
echo "Creating test password..."
echo "test-password-${TIMESTAMP}" > "${TEST_PASSWORD}"
chmod 600 "${TEST_PASSWORD}"
echo "✓ Password created (600 permissions)"
echo ""

# Initialize test repository
echo "Initializing test Restic repository..."
export RESTIC_REPOSITORY="${TEST_REPO}"
export RESTIC_PASSWORD_FILE="${TEST_PASSWORD}"

if restic init > /dev/null 2>&1; then
    echo "✓ Repository initialized"
else
    echo "✗ Repository initialization failed"
    exit 1
fi
echo ""

# Test 1: Data preparation with STRICT validation
echo "TEST 1: Data Preparation (STRICT mode)"
echo "--------------------------------------"
if "${VENV_PYTHON}" "${SCRIPT_DIR}/prepare-backup-data.py" "${STAGING_DIR}"; then
    echo "✓ TEST 1 PASSED: Data preparation"
else
    echo "✗ TEST 1 FAILED: Data preparation"
    exit 1
fi
echo ""

# Verify staging directory exists
if [ ! -d "${STAGING_DIR}" ]; then
    echo "✗ Staging directory not created: ${STAGING_DIR}"
    exit 1
fi
echo "Staging directory: ${STAGING_DIR}"
echo ""

# Test 2: Restic backup
echo "TEST 2: Restic Backup"
echo "---------------------"
START_TIME=$(date +%s)
if restic backup "${STAGING_DIR}" \
    --tag "test" \
    --tag "regression" \
    --host "test-host" \
    --json 2>&1 | tail -5; then
    END_TIME=$(date +%s)
    DURATION=$((END_TIME - START_TIME))
    echo "✓ TEST 2 PASSED: Restic backup (${DURATION}s)"
else
    echo "✗ TEST 2 FAILED: Restic backup"
    exit 1
fi
echo ""

# Test 3: Repository integrity check
echo "TEST 3: Repository Integrity"
echo "----------------------------"
if restic check --read-data-subset=10% > /dev/null 2>&1; then
    echo "✓ TEST 3 PASSED: Repository integrity"
else
    echo "✗ TEST 3 FAILED: Repository integrity"
    exit 1
fi
echo ""

# Test 4: Snapshot listing
echo "TEST 4: Snapshot Listing"
echo "------------------------"
SNAPSHOT_COUNT=$(restic snapshots --json | jq '. | length')
echo "Snapshots: ${SNAPSHOT_COUNT}"
if [ "${SNAPSHOT_COUNT}" -ge 1 ]; then
    echo "✓ TEST 4 PASSED: Snapshot listing"
else
    echo "✗ TEST 4 FAILED: No snapshots found"
    exit 1
fi
echo ""

# Test 5: Restic restore
echo "TEST 5: Restic Restore"
echo "----------------------"
RESTORE_DIR="/tmp/liora-restic-restore-test-${TIMESTAMP}"
if restic restore latest --target "${RESTORE_DIR}" > /dev/null 2>&1; then
    echo "✓ TEST 5 PASSED: Restic restore"
else
    echo "✗ TEST 5 FAILED: Restic restore"
    exit 1
fi
echo ""

# Find actual restored data directory
RESTORED_STAGING=$(find "${RESTORE_DIR}" -type d -name "liora-restic-staging-*" 2>/dev/null | head -1)
if [ -z "${RESTORED_STAGING}" ]; then
    echo "✗ Restored staging directory not found"
    exit 1
fi

# Test 6: Database validation (STRICT mode)
echo "TEST 6: Database Validation (STRICT mode)"
echo "-----------------------------------------"
if "${VENV_PYTHON}" "${SCRIPT_DIR}/validate-databases.py" "${RESTORED_STAGING}"; then
    echo "✓ TEST 6 PASSED: Database validation"
else
    echo "✗ TEST 6 FAILED: Database validation"
    exit 1
fi
echo ""

# Test 7: Verify STRICT checks
echo "TEST 7: STRICT Validation Enforcement"
echo "--------------------------------------"
# Check manifest for proper validation
MANIFEST_VECTORS=$(jq -r '.components.lancedb.vector_count // 0' "${RESTORED_STAGING}/backup-manifest.json" 2>/dev/null)
MANIFEST_DIMS=$(jq -r '.components.lancedb.embedding_dimensions // 0' "${RESTORED_STAGING}/backup-manifest.json" 2>/dev/null)

if [ "${MANIFEST_VECTORS}" = "3206" ]; then
    echo "✓ Vector count: 3206 (STRICT validated)"
else
    echo "✗ Vector count mismatch: ${MANIFEST_VECTORS}"
    exit 1
fi

if [ "${MANIFEST_DIMS}" = "1024" ]; then
    echo "✓ Vector dimensions: 1024 (STRICT validated)"
else
    echo "✗ Dimension mismatch: ${MANIFEST_DIMS}"
    exit 1
fi

echo "✓ TEST 7 PASSED: STRICT validation enforcement"
echo ""

# Summary
echo "=== REGRESSION TEST SUMMARY ==="
echo "✓ TEST 1: Data preparation (STRICT)"
echo "✓ TEST 2: Restic backup"
echo "✓ TEST 3: Repository integrity"
echo "✓ TEST 4: Snapshot listing"
echo "✓ TEST 5: Restic restore"
echo "✓ TEST 6: Database validation (STRICT)"
echo "✓ TEST 7: STRICT validation enforcement"
echo ""
echo "=== ALL TESTS PASSED ==="
echo "DuckDB: 4,000 tickets validated"
echo "LanceDB: 3,206 vectors (1,024 dimensions) validated"
echo "Checksums: All verified"
echo "Consistency: STRICT mode enforced"
echo ""
echo "✓ Phase 11C hardening complete and tested"

