# AWS Backup Cost Estimate - Liora AI Ticket Triage

**Date**: October 13, 2026  
**Instance**: i-07bc3aaf0d692974d (eu-west-1b)  
**Region**: EU (Ireland) - eu-west-1  

---

## Current State (Local Backups Only)

### Storage Costs

**Local Storage** (on EBS root volume):
- Backup data: ~125 MB (databases) + 2 MB (k8s+config) = **127 MB**
- Storage location: /backup/local/
- EBS volume: 60 GB GP3 (already provisioned)
- **Additional cost**: $0/month (uses existing EBS volume)

**Limitations**:
- ✗ No protection against EC2 instance failure
- ✗ No geographic redundancy
- ✗ No off-instance backup storage
- ✗ Single point of failure

### Current Monthly Cost

**Total**: **$0/month** (no additional cost beyond existing EC2 instance)

---

## Proposed State (with IAM Permissions)

### 1. EBS Snapshot Costs

**Snapshot Strategy**:
- Source: 60 GB EBS volume
- Initial snapshot: Full 60 GB backup
- Daily incremental snapshots (typically ~2-5 GB/day for active use)
- Retention: 7 daily snapshots + 4 weekly snapshots
- Total managed recovery points: ~37/month

**Storage Calculation**:
```
Initial snapshot:      60 GB
Daily changes (30d):   2 GB/day × 30 days = 60 GB
Weekly retention:      ~40 GB (compressed, deduplicated)
Total EBS snapshots:   ~120 GB average
```

**Pricing** (EU Ireland):
- EBS Snapshot storage: $0.05 per GB-month
- Total: 120 GB × $0.05 = **$6.00/month**

**Annual**: $72/year

---

### 2. S3 Storage Costs

**Backup Content**:
- Database backups (DuckDB + LanceDB): ~125 MB per backup
- Kubernetes manifests: ~2 MB per backup
- Configuration files: ~52 KB per backup
- Total per backup: ~127 MB

**Retention Strategy**:
- Daily backups: 30 days
- Total storage: 127 MB × 30 = 3,810 MB (~3.8 GB)
- Includes manifest and verification files: ~4 GB total

**Pricing** (S3 Standard, EU Ireland):
- Storage: $0.023 per GB-month
- PUT requests: $0.005 per 1,000 requests
  - Daily backups: 30 PUT/month
- GET requests: $0.0004 per 1,000 requests
  - Verification/restore: ~10 GET/month (negligible)

**Calculation**:
```
Storage:        4 GB × $0.023     = $0.092/month
PUT requests:   30 × $0.000005    = $0.0002/month (negligible)
GET requests:   10 × $0.0000004   = $0.000004/month (negligible)
Total S3:                           $0.10/month (rounded)
```

**Annual**: $1.20/year

---

### 3. AWS Backup Service Costs

**AWS Backup Pricing** (EU Ireland):
- Backup storage: Already counted in EBS snapshot costs
- Restore requests: $0.02 per GB restored
- Early deletion fee: $0.01 per GB (if deleted within retention period)

**Estimated Monthly Cost**:
- Storage management: Included in EBS snapshot cost
- Restore testing (monthly): 60 GB × $0.02 = $1.20/month
- Automation and compliance: Included

**Total AWS Backup Service**: **$1.20/month** (assuming monthly restore test)

**Annual**: $14.40/year

---

### 4. Data Transfer Costs

**S3 Upload** (EC2 to S3 within same region):
- Data transfer: FREE (same region)
- Daily uploads: 127 MB/day = ~4 GB/month
- Cost: **$0/month**

**EBS Snapshot Creation**:
- Snapshot API calls: FREE
- Cost: **$0/month**

---

### 5. CloudWatch Logs (Optional)

**Backup Job Logging**:
- Log ingestion: $0.50 per GB
- Log storage: $0.03 per GB-month
- Estimated logs: ~100 MB/month
- Cost: **$0.08/month**

---

## Total Monthly Cost Summary

| Component | Monthly Cost | Annual Cost |
|-----------|--------------|-------------|
| **Current State (Local Only)** | | |
| Local backups on EBS | $0.00 | $0.00 |
| **Proposed State (Full DR)** | | |
| EBS Snapshots (120 GB) | $6.00 | $72.00 |
| S3 Storage (4 GB) | $0.10 | $1.20 |
| AWS Backup Service | $1.20 | $14.40 |
| CloudWatch Logs | $0.08 | $0.96 |
| **Total Proposed** | **$7.38/month** | **$88.56/year** |

**Rounded Total**: ~**$8/month** or **~$90/year**

---

## Cost Optimization Options

### Option 1: S3 Intelligent-Tiering

**Savings**: ~30% on S3 storage for backups older than 30 days

```
Configuration:
- Frequent Access tier: Days 1-30
- Infrequent Access tier: Days 31-90
- Archive Instant Access: Days 90+

Estimated savings: $0.03/month ($0.36/year)
```

### Option 2: Lifecycle Policies

**Automatically delete old backups**:
```
Daily backups:  7 days retention
Weekly backups: 4 weeks retention
Monthly backups: 12 months retention (if desired)

Estimated savings: $2-3/month
```

### Option 3: EBS Snapshot Archiving

**For long-term retention**:
- EBS Snapshot Archive: $0.0125 per GB-month (75% cheaper)
- Use for monthly snapshots older than 90 days
- Estimated savings: $1-2/month after 6 months

### Option 4: S3 Glacier for Long-Term Archival

**For compliance/audit backups**:
- S3 Glacier Deep Archive: $0.00099 per GB-month
- Use for annual backups requiring 7+ year retention
- Estimated savings: Minimal for current data volume

---

## Cost-Benefit Analysis

### Investment: $8/month (~$90/year)

### Protection Value:

**Data Recovery**:
- Ticket database: 4,000 historical tickets
- Vector embeddings: 3,206 trained vectors (weeks of computation)
- Metrics and analytics: 1,533 triage metrics
- Grafana dashboards: Custom monitoring setup

**Business Continuity**:
- Recovery Time Objective (RTO): 60 minutes vs. hours/days
- Recovery Point Objective (RPO): 24 hours vs. 7+ days
- Customer trust: Maintained vs. Lost
- Development time: Minimal disruption vs. Major setback

**Opportunity Cost of NOT Having Backups**:
- Rebuild time: 40+ hours of engineering
- Lost data: Irreplaceable historical metrics
- Re-training models: 10+ hours of compute
- Customer impact: Service disruption

**Break-Even Analysis**:
- Cost: $8/month
- Value of 1 hour of engineering time: $50-100
- Recovery time saved: 40+ hours
- **Break-even**: First disaster pays back ~60 months of backup costs

---

## Scaling Considerations

### If Data Volume Grows 10×

**Current**: 125 MB databases  
**Future**: 1.25 GB databases  

**Cost Impact**:
```
EBS Snapshots:  $6.00 → $6.50/month  (+$0.50)
S3 Storage:     $0.10 → $1.00/month  (+$0.90)
Total:          $7.38 → $8.40/month  (+$1.02)
```

**Conclusion**: Backup costs scale sub-linearly with data volume.

### If Backup Frequency Increases to Hourly

**Current**: 1 backup/day  
**Future**: 24 backups/day  

**Cost Impact**:
```
S3 Storage:     $0.10 → $2.40/month (+$2.30)
S3 PUT:         Negligible → $0.04/month
Total:          $7.38 → $9.72/month (+$2.34)
```

**Recommendation**: Keep daily backups unless RPO requires hourly.

---

## Budget Approval Request

### One-Time Setup Costs

**None** - All tools already in place:
- ✓ Backup scripts created
- ✓ IAM role exists (just needs policy update)
- ✓ Restore procedures documented
- ✓ Verification tested

### Recurring Monthly Costs

**Requested Budget**: $10/month (rounded for buffer)

**Justification**:
1. Protects $10,000+ of development investment
2. Ensures business continuity
3. Meets production readiness requirements
4. Industry standard practice
5. Required for pre-defense demo reliability

### Approval Checkboxes

- [ ] Approve $10/month AWS backup budget
- [ ] Approve IAM policy changes (see IAM_BACKUP_POLICY.md)
- [ ] Approve automated daily backups
- [ ] Approve S3 bucket creation

---

## Alternative: Manual Backup to External Location

**If AWS Backup budget not approved**:

### Option: Backup to External Git LFS

```bash
# Install Git LFS
git lfs install

# Track database files
git lfs track "*.duckdb"
git lfs track "*.lance"

# Commit backups to private repo
git add -f data/
git commit -m "Backup $(date +%Y%m%d)"
git push backup-repo main
```

**Cost**: $0/month (using existing Git hosting)

**Limitations**:
- Manual process
- Large file limits (GitHub LFS: 2 GB)
- No automated scheduling
- Slower restore process
- Not suitable for rapid disaster recovery

---

## Recommendation

**Approve**: AWS Backup implementation at **$8-10/month**

**Reasoning**:
1. Professional-grade disaster recovery
2. Automated, reliable, tested
3. Minimal cost relative to value protected
4. Industry best practice
5. Essential for production readiness
6. Required before pre-defense demo

**Risk of NOT Approving**:
- Single point of failure (EC2 instance)
- Potential loss of 4,000 tickets + 3,206 vectors
- 40+ hours to rebuild from scratch
- Delayed or failed pre-defense demo
- Loss of credibility

---

**Status**: ⏸ Awaiting budget approval  
**Next Steps**: Apply IAM policy after approval (see IAM_BACKUP_POLICY.md)
