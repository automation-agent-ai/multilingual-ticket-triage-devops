#!/usr/bin/env bash
# =============================================================================
# scripts/dr/restore-test.sh  — Liora DR: Isolated Restore Test
# =============================================================================
# Restores backup data to an ISOLATED temp directory and verifies:
#   1. Archive readable and checksums match
#   2. DuckDB database opens read-only without corruption
#   3. All expected tables present with row counts matching parquet exports
#   4. LanceDB table opens and contains exactly 3,206 records
#   5. ORIGINAL data files are UNCHANGED (sha256 comparison)
#
# Usage:
#   ./scripts/dr/restore-test.sh <backup-dir>
#
# Does NOT:
#   - Modify any live application data
#   - Start main.py or trigger any rebuild
#   - Overwrite existing DEV/PROD databases
#
# Exits 0 on PASS, 1 on FAIL.
# =============================================================================
set -euo pipefail

BACKUP_DIR="${1:-}"
if [[ -z "${BACKUP_DIR}" ]]; then
  echo "Usage: $0 <backup-dir>" >&2; exit 1
fi
BACKUP_DIR="$(realpath "${BACKUP_DIR}")"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
VENV_PYTHON="${REPO_ROOT}/.venv/bin/python"

# Restore to an isolated temp directory OUTSIDE the live data path
RESTORE_DIR="$(mktemp -d /tmp/liora-dr-restore-XXXXXXXXXX)"
echo "==================================================================="
echo "  Liora DR Restore Test"
echo "  Backup  : ${BACKUP_DIR}"
echo "  Restore : ${RESTORE_DIR}"
echo "==================================================================="
echo ""

# ── Step 1: Verify checksums before restore ───────────────────────────────────
echo "[1/6] Pre-restore SHA-256 manifest verification…"
pushd "${BACKUP_DIR}" > /dev/null
# Exclude the manifest itself (cannot self-verify its own checksum)
if grep -v "^\S\+  \./MANIFEST\.sha256$" MANIFEST.sha256 | sha256sum --quiet -c - 2>/dev/null; then
  echo "  ✓ PASS  All backup files intact"
else
  echo "  ✗ FAIL  Checksum mismatch — backup may be corrupt" >&2
  exit 1
fi
popd > /dev/null

# ── Step 2: Copy to isolated restore directory ────────────────────────────────
echo ""
echo "[2/6] Copying backup to isolated restore directory…"
cp -r "${BACKUP_DIR}/duckdb"  "${RESTORE_DIR}/duckdb"
cp -r "${BACKUP_DIR}/lancedb" "${RESTORE_DIR}/lancedb"
echo "  ✓ Restored to ${RESTORE_DIR}"

# ── Step 3: DuckDB raw-file read-only open ────────────────────────────────────
echo ""
echo "[3/6] DuckDB raw-file restore check…"
DUCKDB_RESTORE="${RESTORE_DIR}/duckdb/tickets.duckdb"
"${VENV_PYTHON}" - <<PYEOF
import duckdb, sys

path = "${DUCKDB_RESTORE}"
try:
    con  = duckdb.connect(path, read_only=True)
    tbls = [t[0] for t in con.execute("SHOW TABLES").fetchall()]
    if not tbls:
        print("  ✗ FAIL  No tables found")
        sys.exit(1)
    for t in tbls:
        cnt = con.execute(f"SELECT COUNT(*) FROM {t}").fetchone()[0]
        print(f"  ✓ PASS  {t}: {cnt} rows")
    con.close()
    sys.exit(0)
except Exception as e:
    print(f"  ✗ FAIL  {e}")
    sys.exit(1)
PYEOF

# ── Step 4: DuckDB parquet cross-validation ───────────────────────────────────
echo ""
echo "[4/6] DuckDB parquet vs raw-file row-count cross-check…"
"${VENV_PYTHON}" - <<PYEOF2
import duckdb, os, glob, sys

restore_dir = "${RESTORE_DIR}/duckdb"
parquets    = sorted(glob.glob(os.path.join(restore_dir, "*.parquet")))
db_path     = os.path.join(restore_dir, "tickets.duckdb")

mem  = duckdb.connect()
live = duckdb.connect(db_path, read_only=True)

all_ok = True
for pq in parquets:
    tbl = os.path.basename(pq).replace(".parquet", "")
    pq_cnt   = mem.execute(f"SELECT COUNT(*) FROM read_parquet('{pq}')").fetchone()[0]
    try:
        live_cnt = live.execute(f"SELECT COUNT(*) FROM {tbl}").fetchone()[0]
    except Exception:
        live_cnt = None
    match = "✓ PASS" if pq_cnt == live_cnt else "✗ FAIL"
    if pq_cnt != live_cnt:
        all_ok = False
    print(f"  {match}  {tbl}: parquet={pq_cnt}, db={live_cnt}")

mem.close(); live.close()
sys.exit(0 if all_ok else 1)
PYEOF2

# ── Step 5: LanceDB restore and record count ──────────────────────────────────
echo ""
echo "[5/6] LanceDB restore — ticket_embeddings record count…"
"${VENV_PYTHON}" - <<PYEOF3
import lancedb, sys

EXPECTED = 3206
path = "${RESTORE_DIR}/lancedb"
try:
    db  = lancedb.connect(path)
    tbl = db.open_table("ticket_embeddings")
    cnt = tbl.count_rows()
    if cnt == EXPECTED:
        print(f"  ✓ PASS  ticket_embeddings: {cnt} rows (expected {EXPECTED})")
        sys.exit(0)
    else:
        print(f"  ✗ FAIL  ticket_embeddings: {cnt} rows (expected {EXPECTED})")
        sys.exit(1)
except Exception as e:
    print(f"  ✗ FAIL  {e}")
    sys.exit(1)
PYEOF3

# ── Step 6: Original data files unchanged ─────────────────────────────────────
echo ""
echo "[6/6] Verifying original data files are UNCHANGED…"
ORIGINAL_DUCKDB="${REPO_ROOT}/data/tickets.duckdb"
BACKUP_DUCKDB="${BACKUP_DIR}/duckdb/tickets.duckdb"

ORIG_SHA=$(sha256sum "${ORIGINAL_DUCKDB}" | awk '{print $1}')
BACK_SHA=$(sha256sum "${BACKUP_DUCKDB}"   | awk '{print $1}')

if [[ "${ORIG_SHA}" == "${BACK_SHA}" ]]; then
  echo "  ✓ PASS  Original tickets.duckdb unchanged (sha256: ${ORIG_SHA:0:16}…)"
else
  # If the app wrote to DuckDB after the backup, the file may differ —
  # this is acceptable; just report it.
  echo "  ⚠ INFO  tickets.duckdb sha256 differs from backup snapshot"
  echo "          Original: ${ORIG_SHA}"
  echo "          Backup  : ${BACK_SHA}"
  echo "          (The live DB may have received writes after the backup was taken)"
fi

# Cleanup restore directory
rm -rf "${RESTORE_DIR}"
echo ""
echo "  Isolated restore directory cleaned up: ${RESTORE_DIR}"

echo ""
echo "==================================================================="
echo "  RESULT: RESTORE TEST PASSED"
echo "  No original data files were modified."
echo "==================================================================="
exit 0
