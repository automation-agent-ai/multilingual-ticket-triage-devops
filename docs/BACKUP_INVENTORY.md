# AWS Backup Inventory - Liora AI Ticket Triage

**Date**: October 13, 2026, 00:30 UTC  
**Pre-Defense**: October 13, 2026  

---

## Executive Summary

Complete backup inventory for the Liora AI Ticket Triage AWS infrastructure prior to implementing disaster recovery capabilities.

---

## EC2 Instance

**Instance ID**: `i-07bc3aaf0d692974d`  
**Instance Type**: m6i.xlarge (4 vCPU, 16 GiB RAM)  
**Region**: eu-west-1  
**Availability Zone**: eu-west-1b  
**Private IP**: 172.31.43.47  
**OS**: Ubuntu 24.04.4 LTS  
**Kernel**: 6.17.0-1017-aws  

**IAM Role**: None attached (no instance profile detected)

---

## Storage Configuration

### EBS Volumes

**Root Volume**: `/dev/nvme0n1`  
- **Size**: 60 GB  
- **Used**: 14 GB (24%)  
- **Available**: 44 GB  
- **Filesystem**: ext4  
- **Mount**: `/`  

**Partitions**:
- `/dev/nvme0n1p1`: 59G (root filesystem)
- `/dev/nvme0n1p14`: 4M (BIOS boot)
- `/dev/nvme0n1p15`: 106M (EFI)
- `/dev/nvme0n1p16`: 913M (boot)

**Note**: Single EBS volume configuration. No separate data volumes.

---

## Application Data

### DuckDB (Ticket Database)

**Location**: `/home/ubuntu/workspaces/multilingual-ticket-triage-devops/data/tickets.duckdb`  
**Size**: 26 MB (26,750,976 bytes)  
**MD5 Checksum**: `bf43d96328e5ce996a46fdfd7f52941f`  
**Record Count**: Unable to query (database locked by running application)  
**Status**: Active, in use by DEV and PROD deployments

**Backup Considerations**:
- Database is currently locked by application
- Requires application-consistent backup method
- Cannot simply copy while application is running
- Need to either:
  1. Quiesce application temporarily
  2. Use DuckDB EXPORT functionality
  3. Take EBS snapshot with pre-freeze script

### LanceDB (Vector Embeddings)

**Location**: `/home/ubuntu/workspaces/multilingual-ticket-triage-devops/data/lancedb`  
**Size**: 82 MB  
**Vector Count**: 3,206 embeddings  
**Vector Dimension**: 1,024 (from architecture docs)  
**Table**: `ticket_embeddings`

**File Checksums**:
```
160760ac2853a9dce6a3ec2065af68dd  508ba311-a002-49dd-866b-4efc9eefeebd.lance
160760ac2853a9dce6a3ec2065af68dd  7805cf39-21c8-4a1e-9eab-270c4e62b748.lance
adb1ac9e79f1a0e26cf734c671c51039  010101001000001101000111e2bdc34e91bdc7e172a48a673c.lance
adb1ac9e79f1a0e26cf734c671c51039  1010111101011111101001115127854d75becdf925b53a38fc.lance
adb1ac9e79f1a0e26cf734c671c51039  11011011001101110110001149eb474e2e9933cf8c51b38240.lance
```

**LanceDB Structure**:
```
data/lancedb/
└── ticket_embeddings.lance/
    └── data/
        ├── 508ba311-a002-49dd-866b-4efc9eefeebd.lance
        ├── 7805cf39-21c8-4a1e-9eab-270c4e62b748.lance
        ├── 010101001000001101000111e2bdc34e91bdc7e172a68a673c.lance
        ├── 1010111101011111101001115127854d75becdf925b53a38fc.lance
        └── 11011011001101110110001149eb474e2e9933cf8c51b38240.lance
```

**Backup Considerations**:
- LanceDB is a multi-file format
- All `.lance` files must be backed up together
- Index integrity depends on complete file set
- Can be copied while application is running (read-mostly workload)

---

## Kubernetes Infrastructure

### k3s Configuration

**Version**: v1.36.5+k3s1  
**Datastore**: SQLite (embedded)  
**Datastore Location**: `/var/lib/rancher/k3s/server/db/state.db` (assumed)  
**Storage Backend**: local-path provisioner (rancher.io/local-path)  
**Storage Root**: `/var/lib/rancher/k3s/storage/`

**k3s Service**:
- **Status**: Active (running)
- **Uptime**: 9+ hours
- **Memory**: 5.4 GB
- **Process ID**: 25742

**Backup Considerations**:
- SQLite database requires consistent snapshot
- k3s can be reinstalled, but cluster state needs backup
- Consider exporting resources via kubectl
- Local-path PVs are just directories on host filesystem

### Persistent Volumes

**PV 1: Prometheus Data**
- **PVC**: `triage-monitoring/prometheus-data`
- **Volume ID**: `pvc-6ea56722-08e8-45d6-b8c3-4f2c9ba8d04d`
- **Size**: 10 Gi allocated, 928 KB used
- **Path**: `/var/lib/rancher/k3s/storage/pvc-6ea56722-08e8-45d6-b8c3-4f2c9ba8d04d_triage-monitoring_prometheus-data/`
- **Reclaim Policy**: Delete
- **Access Mode**: ReadWriteOnce

**PV 2: Grafana Data**
- **PVC**: `triage-monitoring/grafana-data`
- **Volume ID**: `pvc-80733fa6-3e83-4f96-8665-66be1e8d0f40`
- **Size**: 2 Gi allocated, 15 MB used
- **Path**: `/var/lib/rancher/k3s/storage/pvc-80733fa6-3e83-4f96-8665-66be1e8d0f40_triage-monitoring_grafana-data/`
- **Reclaim Policy**: Delete
- **Access Mode**: ReadWriteOnce

**Note**: PVs are stored on root volume, not separate EBS volumes.

---

## Application Deployments

### Namespaces

1. **triage-dev**: Development environment
   - Deployment: `ticket-triage` (1/1 Running)
   - Uptime: 4+ hours
   - No persistent volumes

2. **triage-prod**: Production environment
   - Deployment: `ticket-triage` (1/1 Running)
   - Uptime: 3+ hours
   - No persistent volumes

3. **triage-monitoring**: Monitoring stack
   - Prometheus: 1/1 Running
   - Grafana: 1/1 Running
   - 2 PVCs (see above)

**Application Data Mounting**:
- Both DEV and PROD mount DuckDB and LanceDB from host filesystem
- Path: `/home/ubuntu/workspaces/multilingual-ticket-triage-devops/data/`
- Mounted as: `/app/data/` inside containers

---

## Network Configuration

### Nginx Proxies

**Proxy 1: Triage Application**
- **Config**: `/etc/nginx/sites-available/tailscale-proxy`
- **Listen**: `0.0.0.0:8081` (⚠️ not localhost-only)
- **Backend**: `http://10.43.244.137:8000` (triage-prod ClusterIP)

**Proxy 2: Grafana**
- **Config**: `/etc/nginx/sites-available/grafana-proxy`
- **Listen**: `127.0.0.1:8082` (localhost-only ✓)
- **Backend**: `http://10.43.163.173:3000` (grafana ClusterIP)

### Tailscale Serve

**Configuration Status**: Active, persistent

**Route 1**: Triage Application
- **URL**: `https://liora-aws.taila02955.ts.net/` (port 443)
- **Backend**: `http://127.0.0.1:8081`

**Route 2**: Grafana Monitoring
- **URL**: `https://liora-aws.taila02955.ts.net:8443/`
- **Backend**: `http://127.0.0.1:8082`

**Backup Requirement**: Document Tailscale configuration (cannot be backed up as files)

---

## Git Repository Status

**Repository**: `/home/ubuntu/workspaces/multilingual-ticket-triage-devops`  
**Current Branch**: `feat/aws-bedrock-migration`  
**Status**: 20 uncommitted files (staged for commit)

**Uncommitted Changes**:
- AWS migration documentation
- Phase 6/7 deployment records
- AWS Kubernetes overlays (dev/prod)
- Monitoring configuration

**Note**: Infrastructure changes not yet pushed to GitHub.

---

## IAM and AWS Resources

**IAM Role**: None attached to EC2 instance  
**AWS CLI**: Not installed  

**Implications**:
- No automatic AWS Backup service access
- No S3 access for backups without credentials
- Need to configure IAM role for backup operations
- Consider attaching instance profile with backup permissions

---

## Backup Scope Summary

### Critical Data (Must Backup)

1. **DuckDB**: 26 MB
   - Historical ticket data
   - Application database

2. **LanceDB**: 82 MB
   - 3,206 vector embeddings
   - Semantic search index

3. **Kubernetes Manifests**:
   - Current deployments
   - ConfigMaps, Secrets
   - Service definitions

4. **Prometheus Data**: 928 KB
   - Time-series metrics (7-day retention)
   - Optional but valuable

5. **Grafana Configuration**: 15 MB
   - Dashboards
   - Datasources
   - User accounts

### Configuration (Version Control)

1. **Nginx configurations**
2. **Tailscale Serve routes** (documented, not file-based)
3. **k3s manifests** (in Git)
4. **Application code** (in GitHub)

### Non-Critical Data

1. **k3s system components** (can be reinstalled)
2. **Container images** (can be re-pulled)
3. **OS packages** (can be reinstalled)

---

## Total Backup Size Estimate

**Application Data**: ~108 MB (DuckDB + LanceDB)  
**Kubernetes PVs**: ~16 MB (Prometheus + Grafana)  
**Configuration Files**: <1 MB  
**Total Critical Data**: ~125 MB

**EBS Snapshot**: 14 GB (used space) / 60 GB (allocated)

---

## Backup Strategy Requirements

### Application-Consistent Backup Needed For:
- DuckDB (currently locked by application)
- k3s datastore (SQLite)

### File-Level Backup Acceptable For:
- LanceDB (read-mostly)
- Grafana data
- Prometheus data (time-series, can tolerate inconsistency)

---

## Recovery Dependencies

To fully restore the environment, the following are required:

1. **AWS Resources**:
   - EC2 instance in eu-west-1
   - Security groups configured
   - Key pair for SSH access

2. **Software Installation**:
   - Ubuntu 24.04
   - k3s v1.36.5
   - Docker/containerd
   - Nginx
   - Tailscale

3. **Application**:
   - Container image from registry
   - DuckDB backup
   - LanceDB backup
   - Kubernetes manifests

4. **Network**:
   - Tailscale authentication
   - Tailscale Serve configuration
   - Nginx proxy configuration

5. **Data**:
   - Application databases restored
   - Kubernetes PVs restored
   - Grafana dashboards and configuration

---

## Estimated RPO/RTO (Unverified)

**Recovery Point Objective (RPO)**:
- With daily backups: 24 hours maximum data loss
- With EBS snapshots: Point-in-time recovery

**Recovery Time Objective (RTO)**:
- EC2 instance provisioning: ~5 minutes
- Software installation: ~15 minutes
- k3s cluster setup: ~10 minutes
- Data restoration: ~5 minutes (small dataset)
- Application deployment: ~5 minutes
- **Estimated Total RTO**: 40-60 minutes (unverified)

**Note**: These are estimates and must be validated through actual restore testing.

---

## Next Steps

1. **Install AWS CLI** for backup operations
2. **Create/Attach IAM Role** with backup permissions
3. **Configure EBS Snapshots** (daily, 7-day retention)
4. **Implement S3 Backup** for application data
5. **Perform Restore Test** to isolated environment
6. **Document Procedures** for disaster recovery
7. **Automate Backup Process** with scripts

---

## Blockers Identified

1. **No IAM Role**: Cannot use AWS Backup or S3 without credentials
2. **Database Locking**: DuckDB cannot be copied while application runs
3. **No AWS CLI**: Cannot manage AWS resources from instance
4. **Single EBS Volume**: All data on root volume (no separation of concerns)

**Status**: Inventory complete, awaiting approval for IAM role changes
