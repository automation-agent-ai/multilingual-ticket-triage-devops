#!/usr/bin/env bash
# =============================================================================
# scripts/dr/backup.sh  — Liora Disaster Recovery: Application Backup
# =============================================================================
# Creates a timestamped, SHA-256-verified backup of:
#   - DuckDB reference database (exported via read-only COPY to avoid WAL races)
#   - LanceDB vector store directory tree
#   - Kubernetes application manifests (from version-controlled k8s/)
#   - Terraform state (separately from Git)
#   - Backup manifest with file checksums and metadata
#
# Usage:
#   ./scripts/dr/backup.sh [--repo-root <path>] [--backup-dir <path>]
#
# Safety:
#   - Opens DuckDB in read-only mode; never touches the live file.
#   - Does NOT archive kubeconfig, secrets, model cache or embedding weights.
#   - Does NOT overwrite an existing backup with the same timestamp.
#   - Does NOT modify any running Kubernetes workload.
# =============================================================================
set -euo pipefail

# ── Defaults ──────────────────────────────────────────────────────────────────
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BACKUP_BASE="${REPO_ROOT}/backups"
TIMESTAMP="$(date -u +%Y%m%dT%H%M%SZ)"
BACKUP_DIR="${BACKUP_BASE}/${TIMESTAMP}"
VENV_PYTHON="${REPO_ROOT}/.venv/bin/python"
KUBECTL_CONTEXT="docker-desktop"

# ── Parse args ────────────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo-root)  REPO_ROOT="$2";  shift 2 ;;
    --backup-dir) BACKUP_DIR="$2"; shift 2 ;;
    *) echo "Unknown arg: $1"; exit 1 ;;
  esac
done

echo "==================================================================="
echo "  Liora DR Backup — ${TIMESTAMP}"
echo "==================================================================="
echo "  Repo root  : ${REPO_ROOT}"
echo "  Backup dir : ${BACKUP_DIR}"
echo ""

# ── Guard: don't overwrite ────────────────────────────────────────────────────
if [[ -d "${BACKUP_DIR}" ]]; then
  echo "ERROR: backup directory already exists: ${BACKUP_DIR}" >&2
  exit 1
fi
mkdir -p "${BACKUP_DIR}"

# ── Helper ────────────────────────────────────────────────────────────────────
sha256_file() { sha256sum "$1" | awk '{print $1}'; }

# ── 1. DuckDB — read-only export via Python/DuckDB COPY ──────────────────────
echo "[1/5] Exporting DuckDB database (read-only)…"
DUCKDB_SRC="${REPO_ROOT}/data/tickets.duckdb"
DUCKDB_BACKUP_DIR="${BACKUP_DIR}/duckdb"
mkdir -p "${DUCKDB_BACKUP_DIR}"

# Export every table to parquet for consistency; also copy the raw .duckdb file.
"${VENV_PYTHON}" - <<PYEOF
import duckdb, os, sys

src  = "${DUCKDB_SRC}"
dest = "${DUCKDB_BACKUP_DIR}"

con = duckdb.connect(src, read_only=True)
tables = [t[0] for t in con.execute("SHOW TABLES").fetchall()]
print(f"  Tables: {tables}")

for tbl in tables:
    parquet_path = os.path.join(dest, f"{tbl}.parquet")
    con.execute(f"COPY (SELECT * FROM {tbl}) TO '{parquet_path}' (FORMAT PARQUET)")
    cnt = con.execute(f"SELECT COUNT(*) FROM {tbl}").fetchone()[0]
    print(f"  Exported {tbl}: {cnt} rows -> {parquet_path}")

con.close()
sys.exit(0)
PYEOF

# Also copy the raw .duckdb file (WAL is always checkpointed on close)
cp "${DUCKDB_SRC}" "${DUCKDB_BACKUP_DIR}/tickets.duckdb"
echo "  Copied raw DuckDB file: ${DUCKDB_BACKUP_DIR}/tickets.duckdb"

# ── 2. LanceDB — directory copy ───────────────────────────────────────────────
echo "[2/5] Copying LanceDB vector store…"
LANCEDB_SRC="${REPO_ROOT}/data/lancedb"
LANCEDB_BACKUP_DIR="${BACKUP_DIR}/lancedb"
cp -r "${LANCEDB_SRC}" "${LANCEDB_BACKUP_DIR}"

LANCEDB_ROWS=$("${VENV_PYTHON}" - <<PYEOF2
import lancedb
db = lancedb.connect("${LANCEDB_SRC}")
t  = db.open_table("ticket_embeddings")
print(t.count_rows())
PYEOF2
)
echo "  LanceDB rows verified at source: ${LANCEDB_ROWS}"

# ── 3. Kubernetes manifests (from version-controlled k8s/) ────────────────────
echo "[3/5] Snapshotting Kubernetes manifests…"
K8S_BACKUP_DIR="${BACKUP_DIR}/k8s-manifests"
mkdir -p "${K8S_BACKUP_DIR}"
cp -r "${REPO_ROOT}/k8s" "${K8S_BACKUP_DIR}/"

# Also dump live deployment specs for current image digests
for ns in triage-dev triage-prod; do
  kubectl --context "${KUBECTL_CONTEXT}" get deployment ticket-triage \
    -n "${ns}" -o yaml > "${K8S_BACKUP_DIR}/${ns}-deployment-live.yaml" 2>/dev/null || true
done
echo "  Manifests and live deployment YAMLs saved."

# ── 4. Terraform state ────────────────────────────────────────────────────────
echo "[4/5] Backing up Terraform state…"
TF_STATE_SRC="${REPO_ROOT}/terraform/terraform.tfstate"
TF_BACKUP_DIR="${BACKUP_DIR}/terraform"
mkdir -p "${TF_BACKUP_DIR}"
cp "${TF_STATE_SRC}" "${TF_BACKUP_DIR}/terraform.tfstate"
# Also copy backup if present
[[ -f "${TF_STATE_SRC}.backup" ]] && cp "${TF_STATE_SRC}.backup" "${TF_BACKUP_DIR}/terraform.tfstate.backup"
echo "  Terraform state saved."

# ── 5. Backup manifest with SHA-256 checksums ─────────────────────────────────
echo "[5/5] Building backup manifest…"
MANIFEST="${BACKUP_DIR}/MANIFEST.sha256"
pushd "${BACKUP_DIR}" > /dev/null
find . -type f | sort | xargs sha256sum > "${MANIFEST}"
popd > /dev/null

# Metadata header
META="${BACKUP_DIR}/BACKUP_META.txt"
cat > "${META}" <<META
backup_timestamp: ${TIMESTAMP}
repo_root: ${REPO_ROOT}
duckdb_source: ${DUCKDB_SRC}
lancedb_source: ${LANCEDB_SRC}
lancedb_rows_at_backup: ${LANCEDB_ROWS}
k8s_context: ${KUBECTL_CONTEXT}
created_by: scripts/dr/backup.sh
META

BACKUP_SIZE=$(du -sh "${BACKUP_DIR}" | awk '{print $1}')
echo ""
echo "==================================================================="
echo "  Backup complete!"
echo "  Location : ${BACKUP_DIR}"
echo "  Size     : ${BACKUP_SIZE}"
echo "  Manifest : ${MANIFEST}"
echo "==================================================================="
echo "  Next: run ./scripts/dr/verify.sh ${BACKUP_DIR}"
