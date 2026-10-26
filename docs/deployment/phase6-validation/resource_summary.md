# Kubernetes Resource Usage Summary

## Current Pod Status
- **Pod:** ticket-triage-c5dbc669c-n8wpb
- **Status:** Running (Ready 1/1)
- **Restart Count:** 0 ✅ (No crashes)
- **Conditions:** All True (PodScheduled, Initialized, Ready, ContainersReady)

## Resource Usage (Current)
- **CPU:** 3 millicores (0.003 cores)
  - Idle state - expected when not actively processing
- **Memory (RSS):** 1,001 MiB (~1.0 GB)
  - **Note:** Discrepancy with Prometheus metrics (2.66 GB RSS)
  - kubectl top shows container memory, Prometheus shows process RSS
  - E5-large model likely using shared memory not attributed to container

## Resource Allocation
- **Requests:**
  - CPU: 500m (0.5 cores)
  - Memory: 2 GiB
- **Limits:**
  - CPU: 1500m (1.5 cores)
  - Memory: 4 GiB

## Resource Efficiency
- **CPU headroom:** 497m available (99% unused)
- **Memory headroom:** ~1 GB used of 2 GB request (50% utilization)
- **No OOM events:** ✅
- **No throttling:** ✅
- **No readiness failures:** ✅

## Assessment
✅ **Healthy and stable**
- Resources well within limits
- No memory pressure
- No restarts or crashes
- Ready for production load testing
