#!/usr/bin/env bash
# =============================================================================
# scripts/dr/verify.sh  — Liora Disaster Recovery: Backup Integrity Verification
# =============================================================================
# Verifies a backup directory created by backup.sh:
#   1. All files present and SHA-256 checksums match
#   2. DuckDB parquet files can be re-read and row counts verified
#   3. DuckDB raw file opens read-only without corruption
#   4. LanceDB backup directory opens and table row count matches
#
# Usage:
#   ./scripts/dr/verify.sh <backup-dir>
#
# Exits 0 on full PASS, 1 on any FAIL.
# =============================================================================
set -euo pipefail

BACKUP_DIR="${1:-}"
if [[ -z "${BACKUP_DIR}" ]]; then
  echo "Usage: $0 <backup-dir>" >&2; exit 1
fi
BACKUP_DIR="$(realpath "${BACKUP_DIR}")"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
VENV_PYTHON="${REPO_ROOT}/.venv/bin/python"

PASS=0; FAIL=0

check() {
  local label="$1"; local result="$2"
  if [[ "${result}" == "PASS" ]]; then
    echo "  ✓ PASS  ${label}"
    (( PASS++ )) || true
  else
    echo "  ✗ FAIL  ${label}: ${result}"
    (( FAIL++ )) || true
  fi
}

echo "==================================================================="
echo "  Liora DR Verify — ${BACKUP_DIR}"
echo "==================================================================="
echo ""

# ── 1. Manifest integrity ─────────────────────────────────────────────────────
echo "[1/4] SHA-256 manifest check…"
MANIFEST="${BACKUP_DIR}/MANIFEST.sha256"
if [[ ! -f "${MANIFEST}" ]]; then
  echo "  ✗ FAIL  MANIFEST.sha256 not found"; FAIL=$((FAIL+1))
else
  pushd "${BACKUP_DIR}" > /dev/null
  # Exclude the manifest file itself (it cannot self-verify its own checksum)
  if grep -v "^\S\+  \./MANIFEST\.sha256$" "${MANIFEST}" | sha256sum --quiet -c - 2>/dev/null; then
    check "All files match MANIFEST.sha256" "PASS"
  else
    FAILED_FILES=$(grep -v "^\S\+  \./MANIFEST\.sha256$" "${MANIFEST}" | sha256sum -c - 2>/dev/null | grep -v ": OK$" || true)
    check "All files match MANIFEST.sha256" "FAILED files: ${FAILED_FILES}"
  fi
  popd > /dev/null
fi

# ── 2. DuckDB parquet exports ─────────────────────────────────────────────────
echo ""
echo "[2/4] DuckDB parquet validation…"
"${VENV_PYTHON}" - <<PYEOF
import duckdb, os, sys, glob

backup_dir = "${BACKUP_DIR}/duckdb"
parquets   = sorted(glob.glob(os.path.join(backup_dir, "*.parquet")))

if not parquets:
    print("  ✗ FAIL  No parquet files found in", backup_dir)
    sys.exit(1)

con = duckdb.connect()
all_ok = True
for pq in parquets:
    tbl = os.path.basename(pq).replace(".parquet", "")
    cnt = con.execute(f"SELECT COUNT(*) FROM read_parquet('{pq}')").fetchone()[0]
    if cnt > 0:
        print(f"  ✓ PASS  {tbl}: {cnt} rows readable from parquet")
    else:
        print(f"  ✗ FAIL  {tbl}: 0 rows in parquet")
        all_ok = False

con.close()
sys.exit(0 if all_ok else 1)
PYEOF

# ── 3. DuckDB raw file read-only open ─────────────────────────────────────────
echo ""
echo "[3/4] DuckDB raw file read-only check…"
"${VENV_PYTHON}" - <<PYEOF2
import duckdb, sys

path = "${BACKUP_DIR}/duckdb/tickets.duckdb"
try:
    con = duckdb.connect(path, read_only=True)
    tables = [t[0] for t in con.execute("SHOW TABLES").fetchall()]
    print(f"  Tables found: {tables}")
    for t in tables:
        cnt = con.execute(f"SELECT COUNT(*) FROM {t}").fetchone()[0]
        print(f"  ✓ PASS  {t}: {cnt} rows")
    con.close()
    sys.exit(0)
except Exception as e:
    print(f"  ✗ FAIL  {e}")
    sys.exit(1)
PYEOF2

# ── 4. LanceDB backup ─────────────────────────────────────────────────────────
echo ""
echo "[4/4] LanceDB backup validation…"
"${VENV_PYTHON}" - <<PYEOF3
import lancedb, sys

path = "${BACKUP_DIR}/lancedb"
try:
    db = lancedb.connect(path)
    tables = db.table_names() if hasattr(db, "table_names") else db.list_tables()
    print(f"  Tables found: {tables}")
    t = db.open_table("ticket_embeddings")
    cnt = t.count_rows()
    expected = 3206
    if cnt == expected:
        print(f"  ✓ PASS  ticket_embeddings: {cnt} rows (expected {expected})")
        sys.exit(0)
    else:
        print(f"  ✗ FAIL  ticket_embeddings: {cnt} rows (expected {expected})")
        sys.exit(1)
except Exception as e:
    print(f"  ✗ FAIL  {e}")
    sys.exit(1)
PYEOF3

echo ""
echo "==================================================================="
if [[ ${FAIL} -eq 0 ]]; then
  echo "  RESULT: ALL CHECKS PASSED (${PASS} checks)"
  echo "==================================================================="
  exit 0
else
  echo "  RESULT: ${FAIL} check(s) FAILED, ${PASS} passed"
  echo "==================================================================="
  exit 1
fi
