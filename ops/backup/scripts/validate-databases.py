#!/usr/bin/env python3
"""
Phase 11C — Validate Restored Databases

Validates restored backup data:
1. Verifies SHA-256 checksums
2. Opens and validates DuckDB
3. Opens and validates LanceDB
4. Checks expected counts and dimensions

Exit Codes:
    0 = All validations passed
    1 = Checksum validation failed
    2 = DuckDB validation failed
    3 = LanceDB validation failed
    4 = Manifest missing or invalid
"""
import sys
import os
import json
import hashlib
from pathlib import Path
from datetime import datetime, timezone
from typing import Dict, Tuple

# Expected values (STRICT - any mismatch is FATAL)
EXPECTED_TABLES = 5
MIN_TICKETS = 3500
EXPECTED_VECTORS = 3206  # FATAL if mismatch
EXPECTED_DIMENSIONS = 1024  # FATAL if mismatch

def log(message: str, level: str = "INFO") -> None:
    """Log with timestamp"""
    timestamp = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    print(f"[{timestamp}] [{level}] {message}", flush=True)

def sha256_file(filepath: Path) -> str:
    """Calculate SHA-256 hash of file"""
    sha256 = hashlib.sha256()
    with open(filepath, 'rb') as f:
        for chunk in iter(lambda: f.read(8192), b''):
            sha256.update(chunk)
    return sha256.hexdigest()

def verify_checksums(restore_dir: Path) -> bool:
    """Verify SHA-256 checksums"""
    log("Verifying SHA-256 checksums...")
    
    checksum_file = restore_dir / "CHECKSUMS.sha256"
    if not checksum_file.exists():
        log("Checksum file not found", "ERROR")
        return False
    
    # Read expected checksums
    expected = {}
    with open(checksum_file, 'r') as f:
        for line in f:
            if line.strip():
                checksum, filepath = line.strip().split('  ', 1)
                expected[filepath] = checksum
    
    log(f"  Checking {len(expected)} files...")
    
    # Verify each file
    failures = []
    for rel_path, expected_checksum in expected.items():
        if rel_path == "CHECKSUMS.sha256":
            continue
        
        filepath = restore_dir / rel_path
        if not filepath.exists():
            log(f"  ✗ Missing: {rel_path}", "ERROR")
            failures.append(rel_path)
            continue
        
        actual_checksum = sha256_file(filepath)
        if actual_checksum != expected_checksum:
            log(f"  ✗ Mismatch: {rel_path}", "ERROR")
            log(f"    Expected: {expected_checksum}", "ERROR")
            log(f"    Actual:   {actual_checksum}", "ERROR")
            failures.append(rel_path)
    
    if failures:
        log(f"✗ {len(failures)} checksum failures", "ERROR")
        return False
    
    log(f"  ✓ All checksums valid")
    return True

def validate_manifest(restore_dir: Path) -> Tuple[bool, Dict]:
    """Validate and load backup manifest"""
    log("Validating backup manifest...")
    
    manifest_path = restore_dir / "backup-manifest.json"
    if not manifest_path.exists():
        log("Manifest file not found", "ERROR")
        return False, {}
    
    try:
        with open(manifest_path, 'r') as f:
            manifest = json.load(f)
        
        log(f"  Backup timestamp: {manifest.get('backup_timestamp', 'unknown')}")
        log(f"  Backup version: {manifest.get('backup_version', 'unknown')}")
        log(f"  Consistency validated: {manifest.get('consistency_validated', False)}")
        
        return True, manifest
    except Exception as e:
        log(f"Failed to load manifest: {e}", "ERROR")
        return False, {}

def validate_duckdb(restore_dir: Path, manifest: Dict) -> bool:
    """Validate restored DuckDB"""
    log("Validating DuckDB...")
    
    duckdb_path = restore_dir / "tickets.duckdb"
    if not duckdb_path.exists():
        log("DuckDB file not found", "ERROR")
        return False
    
    try:
        import duckdb
        
        conn = duckdb.connect(str(duckdb_path), read_only=True)
        
        # Check tables
        tables = [row[0] for row in conn.execute("SHOW TABLES").fetchall()]
        log(f"  Tables: {len(tables)}")
        
        if len(tables) < EXPECTED_TABLES:
            log(f"  ✗ Expected at least {EXPECTED_TABLES} tables, found {len(tables)}", "ERROR")
            conn.close()
            return False
        
        # Check historical tickets
        ticket_count = conn.execute("SELECT COUNT(*) FROM historical_tickets").fetchone()[0]
        log(f"  Historical tickets: {ticket_count}")
        
        if ticket_count < MIN_TICKETS:
            log(f"  ✗ Expected at least {MIN_TICKETS} tickets, found {ticket_count}", "ERROR")
            conn.close()
            return False
        
        # Compare with manifest
        expected_tickets = manifest.get('components', {}).get('duckdb', {}).get('historical_tickets', 0)
        if expected_tickets and ticket_count != expected_tickets:
            log(f"  ⚠ Manifest shows {expected_tickets} tickets, found {ticket_count}", "WARN")
        
        # Check all tables
        for table in tables:
            count = conn.execute(f"SELECT COUNT(*) FROM {table}").fetchone()[0]
            log(f"    {table}: {count} rows")
        
        conn.close()
        
        log("  ✓ DuckDB validation passed")
        return True
        
    except Exception as e:
        log(f"DuckDB validation failed: {e}", "ERROR")
        return False

def validate_lancedb(restore_dir: Path, manifest: Dict) -> bool:
    """
    Validate restored LanceDB with STRICT checks.
    
    Enforces:
    1. Exact vector count (EXPECTED_VECTORS = 3206) - FATAL if mismatch
    2. Explicit dimension verification (EXPECTED_DIMENSIONS = 1024) - FATAL if mismatch
    3. Schema integrity
    """
    log("Validating LanceDB (STRICT mode)...")
    
    lancedb_dir = restore_dir / "lancedb"
    if not lancedb_dir.exists():
        log("LanceDB directory not found", "ERROR")
        return False
    
    try:
        import lancedb
        import pyarrow as pa
        
        db = lancedb.connect(str(lancedb_dir))
        tbl = db.open_table("ticket_embeddings")
        
        # STRICT CHECK: Vector count must match exactly
        vector_count = tbl.count_rows()
        log(f"  Vectors: {vector_count}")
        
        if vector_count != EXPECTED_VECTORS:
            log(f"FATAL: Expected exactly {EXPECTED_VECTORS} vectors, found {vector_count}", "ERROR")
            log("Vector count mismatch indicates corrupted or incomplete restore.", "ERROR")
            return False
        
        log(f"  ✓ Vector count verified: {vector_count}")
        
        # Compare with manifest
        expected_vectors = manifest.get('components', {}).get('lancedb', {}).get('vector_count', 0)
        if expected_vectors and vector_count != expected_vectors:
            log(f"FATAL: Manifest shows {expected_vectors} vectors, but found {vector_count}", "ERROR")
            return False
        
        # STRICT CHECK: Find vector field and verify dimensions
        schema = tbl.schema
        log(f"  Schema fields: {len(schema)}")
        
        embedding_field = None
        embedding_dimensions = None
        
        for field in schema:
            # Look for vector field (may be called "vector", "embedding", or similar)
            if field.name in ('vector', 'embedding', 'embeddings'):
                embedding_field = field
                # Check if it's a fixed-size list type
                if hasattr(field.type, 'list_size'):
                    # FixedSizeList type - get dimensions directly
                    embedding_dimensions = field.type.list_size
                elif isinstance(field.type, pa.ListType):
                    # Variable length list - need to sample data
                    log("  Vector field is variable-length list, sampling first row...", "INFO")
                    try:
                        first_row = tbl.to_pandas().iloc[0]
                        if field.name in first_row:
                            embedding_dimensions = len(first_row[field.name])
                    except Exception as e:
                        log(f"  Could not sample vector dimensions: {e}", "WARN")
                break
        
        if not embedding_field:
            log("FATAL: No vector/embedding field found in schema", "ERROR")
            log(f"  Available fields: {[f.name for f in schema]}", "ERROR")
            return False
        
        log(f"  ✓ Vector field: {embedding_field.name}")
        
        # STRICT CHECK: Verify dimensions = 1024
        if embedding_dimensions:
            log(f"  Vector dimensions: {embedding_dimensions}")
            if embedding_dimensions != EXPECTED_DIMENSIONS:
                log(f"FATAL: Expected {EXPECTED_DIMENSIONS} dimensions, found {embedding_dimensions}", "ERROR")
                return False
            log(f"  ✓ Dimensions verified: {embedding_dimensions}")
        else:
            log("FATAL: Could not determine vector dimensions", "ERROR")
            log(f"  Field type: {embedding_field.type}", "ERROR")
            return False
        
        # Verify with manifest if available
        manifest_dims = manifest.get('components', {}).get('lancedb', {}).get('embedding_dimensions')
        if manifest_dims and manifest_dims != embedding_dimensions:
            log(f"FATAL: Manifest shows {manifest_dims} dimensions, found {embedding_dimensions}", "ERROR")
            return False
        
        log("  ✓ STRICT LanceDB validation passed")
        return True
        
    except Exception as e:
        log(f"LanceDB validation failed: {e}", "ERROR")
        return False

def main():
    """Main validation"""
    log("=== Phase 11C Restore Validation Starting ===")
    
    if len(sys.argv) < 2:
        log("Usage: validate-databases.py <restore-dir>", "ERROR")
        sys.exit(1)
    
    restore_dir = Path(sys.argv[1])
    
    if not restore_dir.exists():
        log(f"Restore directory not found: {restore_dir}", "ERROR")
        sys.exit(1)
    
    log(f"Restore directory: {restore_dir}")
    
    # Load manifest
    manifest_valid, manifest = validate_manifest(restore_dir)
    if not manifest_valid:
        log("Manifest validation failed", "ERROR")
        sys.exit(4)
    
    # Verify checksums
    if not verify_checksums(restore_dir):
        log("Checksum validation failed", "ERROR")
        sys.exit(1)
    
    # Validate DuckDB
    if not validate_duckdb(restore_dir, manifest):
        log("DuckDB validation failed", "ERROR")
        sys.exit(2)
    
    # Validate LanceDB
    if not validate_lancedb(restore_dir, manifest):
        log("LanceDB validation failed", "ERROR")
        sys.exit(3)
    
    # Success
    log("=== Restore Validation Complete ===")
    log("✓ All validations passed")
    log("✓ Checksums verified")
    log("✓ DuckDB validated")
    log("✓ LanceDB validated")
    log("✓ Restore is consistent and complete")
    
    sys.exit(0)

if __name__ == "__main__":
    main()
