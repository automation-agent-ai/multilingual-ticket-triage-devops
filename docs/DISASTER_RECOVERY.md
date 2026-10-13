# Disaster Recovery Plan - Liora AI Ticket Triage

**Version**: 1.0  
**Date**: October 13, 2026  
**Instance**: i-07bc3aaf0d692974d (eu-west-1b)  
**RPO**: 24 hours (unverified)  
**RTO**: 60 minutes (unverified)  

---

## Table of Contents

1. [Backup Architecture](#backup-architecture)
2. [Backup Inventory](#backup-inventory)
3. [Backup Procedures](#backup-procedures)
4. [Restore Procedures](#restore-procedures)
5. [Complete Disaster Recovery](#complete-disaster-recovery)
6. [Recovery Testing](#recovery-testing)
7. [Operational Runbook](#operational-runbook)

---

## Backup Architecture

### Current Implementation

**Backup Strategy**: Three-tier backup approach

```
┌─────────────────────────────────────────────────────────────┐
│                    BACKUP TIERS                              │
├─────────────────────────────────────────────────────────────┤
│                                                              │
│  Tier 1: Application Data (125 MB)                          │
│  ├─ DuckDB: 26 MB (4,000 historical tickets + metrics)     │
│  ├─ LanceDB: 82 MB (3,206 vectors, dim=1024)               │
│  └─ Verified restoration: ✓ Passed                          │
│                                                              │
│  Tier 2: Kubernetes State (1.7 MB)                          │
│  ├─ Manifests (deployments, services, configmaps)           │
│  ├─ PVCs (Prometheus: 10Gi, Grafana: 2Gi)                  │
│  └─ Secrets (base64, requires encryption at rest)           │
│                                                              │
│  Tier 3: System Configuration (52 KB)                       │
│  ├─ Nginx proxies (tailscale-proxy, grafana-proxy)         │
│  ├─ Tailscale Serve documentation                           │
│  └─ k3s systemd service                                     │
│                                                              │
└─────────────────────────────────────────────────────────────┘
```

### Storage Locations

**Local Backups** (Current):
- Path: `/backup/local/`
- Retention: Manual cleanup required
- Protection: None (on same EBS volume)
- Status: ✓ Implemented and tested

**Remote Backups** (Pending IAM approval):
- EBS Snapshots: AWS Backup vault
- S3 Backups: `s3://liora-triage-backups-523231704152/`
- Retention: 7 daily + 4 weekly
- Status: ⏸ Requires IAM policy changes (see IAM_BACKUP_POLICY.md)

---

## Backup Inventory

### Critical Data Assets

| Asset | Location | Size | Verified | Critical |
|-------|----------|------|----------|----------|
| DuckDB | `/home/ubuntu/workspaces/.../data/tickets.duckdb` | 26 MB | ✓ | Yes |
| LanceDB | `/home/ubuntu/workspaces/.../data/lancedb/` | 82 MB | ✓ | Yes |
| Prometheus PV | `/var/lib/rancher/k3s/storage/pvc-6ea5.../` | 928 KB | ✓ | Medium |
| Grafana PV | `/var/lib/rancher/k3s/storage/pvc-8073.../` | 15 MB | ✓ | Medium |
| K8s Manifests | `/backup/local/k8s/` | 1.7 MB | ✓ | Yes |
| Nginx Configs | `/etc/nginx/sites-available/` | <1 KB | ✓ | Yes |

### Reference Counts (for Verification)

- **DuckDB Tables**: 5 tables
  - `historical_tickets`: 4,000 rows
  - `triage_predictions`: 4,676 rows
  - `triage_metrics`: 1,533 rows
  - `triage_confusion_matrix`: 1,461 rows
  - `triage_runs`: 59 rows

- **LanceDB Vectors**: 3,206 embeddings
- **Vector Dimension**: 1,024
- **LanceDB Files**: 6 `.lance` files

### Current Backup Checksums

**DuckDB**: `bf43d96328e5ce996a46fdfd7f52941f`

**LanceDB** (sorted by MD5):
```
160760ac2853a9dce6a3ec2065af68dd  (2 files)
adb1ac9e79f1a0e26cf734c671c51039  (3 files)
```

---

## Backup Procedures

### Automated Daily Backup

**Script**: `/home/ubuntu/backup-scripts/backup-all.sh`

**Schedule** (to be implemented via cron):
```bash
# Run daily at 2 AM UTC
0 2 * * * /home/ubuntu/backup-scripts/backup-all.sh >> /var/log/triage-backup.log 2>&1
```

**Manual Execution**:
```bash
cd /home/ubuntu/backup-scripts
./backup-all.sh
```

### Individual Component Backups

**Database Only**:
```bash
/home/ubuntu/backup-scripts/backup-databases.sh
```

**Kubernetes Only**:
```bash
/home/ubuntu/backup-scripts/backup-kubernetes.sh
```

**Configuration Only**:
```bash
/home/ubuntu/backup-scripts/backup-config.sh
```

### Backup Verification

**Verify Latest Backup**:
```bash
LATEST_DB_BACKUP=$(ls -1t /backup/local/databases/ | head -1)
/backup/local/databases/${LATEST_DB_BACKUP}/verify-restore.sh
```

### Important Considerations

#### DuckDB Consistency

**Warning**: DuckDB may not be transaction-consistent if copied while the application is running.

**For Production Backups**:
```bash
# Scale down applications
kubectl scale -n triage-dev deploy/ticket-triage --replicas=0
kubectl scale -n triage-prod deploy/ticket-triage --replicas=0

# Wait for pods to terminate
kubectl wait --for=delete pod -l app=ticket-triage -n triage-dev --timeout=60s
kubectl wait --for=delete pod -l app=ticket-triage -n triage-prod --timeout=60s

# Run backup
/home/ubuntu/backup-scripts/backup-databases.sh

# Scale back up
kubectl scale -n triage-dev deploy/ticket-triage --replicas=1
kubectl scale -n triage-prod deploy/ticket-triage --replicas=1
```

**Downtime**: ~5 minutes

---

## Restore Procedures

### Database Restoration

#### Test Restore (Safe, Isolated)

```bash
# List available backups
ls -1 /backup/local/databases/

# Restore to test directory
cd /home/ubuntu/backup-scripts
./restore-databases.sh 20261012_223002
```

Restored data will be in `/tmp/restore-test-<timestamp>/`

#### Production Restore (⚠️ DANGER)

**Prerequisites**:
1. Confirm backup timestamp is correct
2. Scale down DEV and PROD deployments
3. Backup current data before overwriting
4. Have rollback plan ready

**Procedure**:
```bash
# Step 1: Scale down applications
kubectl scale -n triage-dev deploy/ticket-triage --replicas=0
kubectl scale -n triage-prod deploy/ticket-triage --replicas=0

# Step 2: Backup current state (just in case)
cp -a /home/ubuntu/workspaces/multilingual-ticket-triage-devops/data /home/ubuntu/data-pre-restore-$(date +%Y%m%d_%H%M%S)

# Step 3: Restore data
BACKUP_TIMESTAMP="20261012_223002"  # Use actual timestamp
BACKUP_DIR="/backup/local/databases/${BACKUP_TIMESTAMP}"
DATA_DIR="/home/ubuntu/workspaces/multilingual-ticket-triage-devops/data"

# Restore LanceDB
rsync -a --delete "${BACKUP_DIR}/lancedb/" "${DATA_DIR}/lancedb/"

# Restore DuckDB
cp "${BACKUP_DIR}/tickets.duckdb" "${DATA_DIR}/tickets.duckdb"

# Step 4: Verify checksums
md5sum "${DATA_DIR}/tickets.duckdb"
# Should match backup manifest

# Step 5: Scale up applications
kubectl scale -n triage-dev deploy/ticket-triage --replicas=1
kubectl scale -n triage-prod deploy/ticket-triage --replicas=1

# Step 6: Verify applications are healthy
kubectl get pods -n triage-dev -w
kubectl get pods -n triage-prod -w
```

**Estimated Time**: 10-15 minutes

### Kubernetes Restoration

#### Restore All Kubernetes Resources

```bash
BACKUP_TIMESTAMP="20261012_223211"  # Use actual timestamp
BACKUP_DIR="/backup/local/k8s/${BACKUP_TIMESTAMP}"

# Method 1: Restore specific resources
kubectl apply -f "${BACKUP_DIR}/deployments.yaml"
kubectl apply -f "${BACKUP_DIR}/services.yaml"
kubectl apply -f "${BACKUP_DIR}/configmaps.yaml"

# Method 2: Restore entire namespace
kubectl apply -f "${BACKUP_DIR}/namespaces/triage-dev/all-resources.yaml"
kubectl apply -f "${BACKUP_DIR}/namespaces/triage-prod/all-resources.yaml"
kubectl apply -f "${BACKUP_DIR}/namespaces/triage-monitoring/all-resources.yaml"
```

#### Restore Persistent Volume Data

**Prometheus**:
```bash
sudo rsync -a /backup/local/databases/.../prometheus-backup/ \
  /var/lib/rancher/k3s/storage/pvc-6ea56722-08e8-45d6-b8c3-4f2c9ba8d04d_triage-monitoring_prometheus-data/
```

**Grafana**:
```bash
sudo rsync -a /backup/local/databases/.../grafana-backup/ \
  /var/lib/rancher/k3s/storage/pvc-80733fa6-3e83-4f96-8665-66be1e8d0f40_triage-monitoring_grafana-data/
```

---

## Complete Disaster Recovery

### Scenario: Total EC2 Instance Loss

**Time Estimate**: 60-90 minutes (unverified)

### Prerequisites

- AWS account access
- Security group configuration known
- SSH key pair available
- Backup files accessible (S3 or EBS snapshot)
- Tailscale account credentials

### Recovery Steps

#### Phase 1: Provision Infrastructure (15 min)

```bash
# 1. Launch new EC2 instance
aws ec2 run-instances \
  --image-id ami-04df7d76c1b804451 \
  --instance-type m6i.xlarge \
  --key-name <your-key> \
  --security-group-ids <sg-id> \
  --subnet-id <subnet-id> \
  --iam-instance-profile Name=liora-triage-bedrock-role \
  --block-device-mappings '[{
    "DeviceName": "/dev/sda1",
    "Ebs": {
      "VolumeSize": 60,
      "VolumeType": "gp3"
    }
  }]' \
  --tag-specifications 'ResourceType=instance,Tags=[{Key=Name,Value=liora-triage-aws},{Key=Project,Value=liora-triage}]'

# 2. Wait for instance to be running
aws ec2 wait instance-running --instance-ids <instance-id>

# 3. Get public IP
INSTANCE_IP=$(aws ec2 describe-instances \
  --instance-ids <instance-id> \
  --query 'Reservations[0].Instances[0].PublicIpAddress' \
  --output text)
```

#### Phase 2: Install Software (20 min)

```bash
# SSH into new instance
ssh -i <key.pem> ubuntu@${INSTANCE_IP}

# Update system
sudo apt-get update && sudo apt-get upgrade -y

# Install k3s
curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION=v1.36.5+k3s1 sh -

# Install Docker (if needed)
sudo apt-get install -y docker.io
sudo usermod -aG docker ubuntu

# Install Nginx
sudo apt-get install -y nginx

# Install Tailscale
curl -fsSL https://tailscale.com/install.sh | sh
sudo tailscale up

# Install AWS CLI
curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "/tmp/awscliv2.zip"
cd /tmp && sudo apt-get install -y unzip && unzip -q awscliv2.zip
sudo ./aws/install

# Set up kubectl
sudo cp /etc/rancher/k3s/k3s.yaml ~/.kube/config
sudo chown ubuntu:ubuntu ~/.kube/config
```

#### Phase 3: Restore Data (15 min)

```bash
# Clone application repository
cd /home/ubuntu
mkdir -p workspaces
cd workspaces
git clone <your-repo-url> multilingual-ticket-triage-devops
cd multilingual-ticket-triage-devops

# Create data directory
mkdir -p data

# Retrieve backup from S3 (if IAM permissions exist)
aws s3 sync s3://liora-triage-backups-523231704152/latest/ /tmp/backup/

# Restore databases
rsync -a /tmp/backup/lancedb/ data/lancedb/
cp /tmp/backup/tickets.duckdb data/tickets.duckdb

# Verify restoration
md5sum data/tickets.duckdb
# Compare with backup manifest
```

#### Phase 4: Deploy Applications (10 min)

```bash
# Deploy DEV environment
kubectl apply -k k8s/overlays/aws-dev/

# Deploy PROD environment
kubectl apply -k k8s/overlays/aws-prod/

# Deploy monitoring
kubectl apply -k k8s/aws-monitoring/

# Wait for deployments
kubectl wait --for=condition=available --timeout=300s \
  deployment/ticket-triage -n triage-dev

kubectl wait --for=condition=available --timeout=300s \
  deployment/ticket-triage -n triage-prod
```

#### Phase 5: Configure Network (10 min)

```bash
# Restore Nginx configurations
sudo cp /tmp/backup/config/nginx/* /etc/nginx/sites-available/
sudo ln -sf /etc/nginx/sites-available/tailscale-proxy /etc/nginx/sites-enabled/
sudo ln -sf /etc/nginx/sites-available/grafana-proxy /etc/nginx/sites-enabled/
sudo nginx -t && sudo systemctl reload nginx

# Configure Tailscale Serve
sudo tailscale serve --bg --https 443 http://127.0.0.1:8081
sudo tailscale serve --bg --https 8443 http://127.0.0.1:8082
```

#### Phase 6: Verification (10 min)

```bash
# Test application endpoints
kubectl get pods -A
kubectl get svc -A

# Test DEV
DEV_POD=$(kubectl get pods -n triage-dev -l app=ticket-triage -o jsonpath='{.items[0].metadata.name}')
kubectl exec -n triage-dev ${DEV_POD} -- python -c "
import lancedb
db = lancedb.connect('/app/data/lancedb')
table = db.open_table('ticket_embeddings')
print(f'Vectors: {table.count_rows()}')
"

# Test PROD
PROD_POD=$(kubectl get pods -n triage-prod -l app=ticket-triage -o jsonpath='{.items[0].metadata.name}')
kubectl logs -n triage-prod ${PROD_POD} --tail=50

# Test external access
curl -k https://liora-aws.taila02955.ts.net/health
curl -k https://liora-aws.taila02955.ts.net:8443/api/health
```

---

## Recovery Testing

### Monthly DR Test Checklist

**Test Schedule**: Last Saturday of each month at 14:00 UTC

1. **Backup Verification**
   - [ ] Run `/backup/local/databases/<latest>/verify-restore.sh`
   - [ ] Verify checksums match manifest
   - [ ] Confirm 3,206 LanceDB vectors present

2. **Test Restore**
   - [ ] Execute isolated restore to /tmp/
   - [ ] Verify DuckDB 4,000 tickets
   - [ ] Verify LanceDB dimension 1,024
   - [ ] Document restore time

3. **Backup Rotation**
   - [ ] Verify daily backups for last 7 days exist
   - [ ] Clean up backups older than 30 days
   - [ ] Check disk usage: /backup should be < 10 GB

4. **Documentation Update**
   - [ ] Update this document with actual RTO
   - [ ] Note any issues encountered
   - [ ] Update contact information if changed

---

## Operational Runbook

### Daily Operations

**Backup Schedule**:
- **Time**: 02:00 UTC daily
- **Duration**: ~2 minutes
- **Retention**: 30 days local, 7 daily + 4 weekly remote (pending)

**Monitoring**:
```bash
# Check last backup status
tail -50 /var/log/triage-backup.log

# Check backup disk usage
du -sh /backup/local/

# List recent backups
ls -lht /backup/local/databases/ | head -10
```

### Emergency Procedures

#### Corrupted Database Detected

```bash
# 1. Stop applications immediately
kubectl scale deploy/ticket-triage -n triage-dev --replicas=0
kubectl scale deploy/ticket-triage -n triage-prod --replicas=0

# 2. Identify last known good backup
ls -lt /backup/local/databases/

# 3. Restore from backup (see Restore Procedures above)

# 4. Resume operations
```

#### Disk Space Critical

```bash
# Check usage
df -h /

# Clean old local backups (keep last 7 days)
find /backup/local/ -name "202*" -type d -mtime +7 -exec rm -rf {} \;

# Clean Docker images
docker system prune -af --volumes
```

#### Recovery Point Objective Breached

**If backup fails for >24 hours**:

1. Alert: Notify operations team
2. Check: Verify backup script permissions
3. Run: Manual backup immediately
4. Investigate: Check logs in `/var/log/triage-backup.log`
5. Document: Note cause and prevention steps

### Contact Information

**Primary**: DevOps Team (placeholder)  
**Secondary**: AWS Support (Enterprise plan)  
**Escalation**: CTO (placeholder)  

---

## RPO/RTO Targets

### Current Metrics (Unverified)

| Metric | Target | Actual | Status |
|--------|--------|--------|--------|
| **RPO** (Recovery Point Objective) | 24 hours | 24 hours | ⏳ Unverified |
| **RTO** (Recovery Time Objective) | 60 minutes | 60-90 min | ⏳ Unverified |
| **Backup Frequency** | Daily | Daily | ✓ Implemented |
| **Backup Verification** | Monthly | Monthly | ⏳ Not scheduled |
| **DR Test Frequency** | Quarterly | Never | ✗ Not scheduled |

**Note**: Metrics marked "Unverified" require actual disaster recovery drill to confirm.

---

## Version History

| Version | Date | Changes | Author |
|---------|------|---------|--------|
| 1.0 | 2026-10-13 | Initial disaster recovery plan created | Agent (Phase 11) |

---

## Appendix

### Backup File Structure

```
/backup/local/
├── databases/
│   └── 20261012_223002/
│       ├── lancedb/
│       │   └── ticket_embeddings.lance/
│       ├── tickets.duckdb
│       ├── manifest.json
│       ├── lancedb.checksums
│       └── verify-restore.sh
├── k8s/
│   └── 20261012_223211/
│       ├── namespaces.yaml
│       ├── deployments.yaml
│       ├── services.yaml
│       ├── configmaps.yaml
│       ├── pvcs.yaml
│       ├── pvs.yaml
│       ├── secrets.yaml
│       └── manifest.json
└── config/
    └── 20261012_223247/
        ├── nginx/
        ├── tailscale/
        ├── systemd/
        └── manifest.json
```

### Useful Commands

**Check application health**:
```bash
kubectl get pods -A
kubectl top nodes
kubectl top pods -A
```

**Database integrity check**:
```bash
cd /home/ubuntu/workspaces/multilingual-ticket-triage-devops
source .venv/bin/activate
python -c "
import duckdb, lancedb
duck_conn = duckdb.connect('data/tickets.duckdb', read_only=True)
lance_db = lancedb.connect('data/lancedb')
lance_table = lance_db.open_table('ticket_embeddings')
print(f'DuckDB tickets: {duck_conn.execute(\"SELECT COUNT(*) FROM historical_tickets\").fetchone()[0]}')
print(f'LanceDB vectors: {lance_table.count_rows()}')
duck_conn.close()
"
```

**Network connectivity test**:
```bash
# From external machine
curl -k https://liora-aws.taila02955.ts.net/health
curl -k https://liora-aws.taila02955.ts.net:8443/api/health
```

---

**Document Status**: ✓ Complete, ⏸ Awaiting IAM approval for remote backups
