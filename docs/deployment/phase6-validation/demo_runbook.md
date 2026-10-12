# AWS DEV Ticket Triage Demo Runbook
**20-Minute Liora Pre-Defense Demo**  
**Date:** 2026-10-12  
**Environment:** AWS EC2 k3s DEV (triage-dev namespace)

---

## Prerequisites (Verify Before Demo)
```bash
# SSH to AWS EC2 instance
ssh ubuntu@<aws-ec2-ip>

# Verify kubectl context
kubectl config current-context  # Should show 'default'

# Verify cluster status
kubectl cluster-info
```

---

## Demo Flow (8-10 minutes)

### 1. Show the Cluster (30 seconds)
```bash
# Show Kubernetes cluster
kubectl get nodes -o wide

# Expected output:
# NAME              STATUS   ROLES           AGE   VERSION        INTERNAL-IP
# ip-172-31-43-47   Ready    control-plane   Xh    v1.36.5+k3s1   172.31.43.47
```

### 2. Show the Deployment (1 minute)
```bash
# Show namespace and resources
kubectl get all -n triage-dev

# Expected output:
# NAME                                READY   STATUS    RESTARTS   AGE
# pod/ticket-triage-c5dbc669c-xxxxx   1/1     Running   0          Xm
#
# NAME                    TYPE        CLUSTER-IP     PORT(S)
# service/ticket-triage   ClusterIP   10.43.x.x      8000/TCP
#
# NAME                            READY   UP-TO-DATE   AVAILABLE
# deployment.apps/ticket-triage   1/1     1            1

# Show pod details
kubectl get pod -n triage-dev -o wide

# Show image reference
kubectl get deployment ticket-triage -n triage-dev \
  -o jsonpath='{.spec.template.spec.containers[0].image}'

# Expected: ghcr.io/automation-agent-ai/multilingual-ticket-triage-devops:aws-sha-bbe590a...
```

### 3. Verify Health (30 seconds)
```bash
# Check health and readiness
kubectl exec -n triage-dev deployment/ticket-triage -- \
  curl -s http://localhost:8000/health | jq

# Expected: {"status":"ok"}

kubectl exec -n triage-dev deployment/ticket-triage -- \
  curl -s http://localhost:8000/ready | jq

# Expected: {"ready":true,"agent_initialized":true}
```

### 4. Show Configuration (1 minute)
```bash
# Show Bedrock configuration
kubectl exec -n triage-dev deployment/ticket-triage -- \
  cat /app/config-aws.yaml | head -30

# Highlight:
# - provider: bedrock
# - model_name: eu.amazon.nova-micro-v1:0
# - region: eu-west-1
# - embedding: intfloat/multilingual-e5-large

# Verify IAM authentication (no static keys)
kubectl exec -n triage-dev deployment/ticket-triage -- \
  printenv | grep -E "AWS_REGION|CONFIG_PATH"

# Expected:
# AWS_REGION=eu-west-1
# CONFIG_PATH=/app/config-aws.yaml
```

### 5. Process a Live Ticket (2-3 minutes)
```bash
# Start port-forward in background
kubectl port-forward -n triage-dev svc/ticket-triage 8000:8000 &
PF_PID=$!
sleep 2

# Submit a German insurance claim (demonstrates multilingual support)
curl -X POST http://localhost:8000/triage \
  -H "Content-Type: application/json" \
  -d '{
    "ticket_id": "DEMO-CLAIM-DE-001",
    "subject": "Wasserschaden in meiner Wohnung",
    "body": "Guten Tag, ich hatte gestern einen schweren Wasserschaden in meiner Wohnung. Ein Rohr ist geplatzt und hat große Teile meines Wohnzimmers überflutet. Ich habe Fotos gemacht und den Schaden sofort gemeldet. Ich brauche dringend einen Gutachter und möchte wissen, wie ich den Schaden einreichen kann. Meine Versicherungsnummer ist 4567-8901-2345."
  }' | jq '.'

# Expected response (in ~1 second):
# {
#   "ticket_id": "DEMO-CLAIM-DE-001",
#   "topic": "Claims / Damage",
#   "urgency": "High",
#   "next_action": "escalate_to_human_supervisor",
#   "confidence": 0.95,
#   "missing_info": false,
#   "missing_fields": [],
#   "requires_human_review": true,
#   "short_note": "Burst pipe caused severe water damage; urgent adjuster needed.",
#   "action_result": {
#     "selected_action": "escalate_to_human_supervisor",
#     "action_status": "simulated_success",
#     "target": "human_supervisor_queue"
#   }
# }

# Stop port-forward
kill $PF_PID
```

**Key Talking Points:**
- ✅ German text processed correctly (multilingual E5-large embeddings)
- ✅ Classified as "Claims / Damage" with High urgency
- ✅ Routed to human supervisor (appropriate for complex claim)
- ✅ High confidence (0.95)
- ✅ Response time ~1 second

### 6. Show Metrics (1-2 minutes)
```bash
# Restart port-forward
kubectl port-forward -n triage-dev svc/ticket-triage 8000:8000 &
PF_PID=$!
sleep 2

# Check Prometheus metrics
curl -s http://localhost:8000/metrics | grep 'http_requests_total{method="POST"'
curl -s http://localhost:8000/metrics | grep 'http_request_duration_seconds_sum{method="POST"'

# Show resource usage
kubectl top pod -n triage-dev

# Expected:
# NAME                            CPU(cores)   MEMORY(bytes)
# ticket-triage-c5dbc669c-xxxxx   <10m         ~1000Mi

kill $PF_PID
```

### 7. Show Bedrock Verification (1 minute)
```bash
# Direct Bedrock API test from pod
kubectl exec -n triage-dev deployment/ticket-triage -- \
  python3 -c "
import boto3
client = boto3.client('bedrock-runtime', region_name='eu-west-1')
response = client.converse(
    modelId='eu.amazon.nova-micro-v1:0',
    messages=[{'role': 'user', 'content': [{'text': 'Say hello'}]}],
    inferenceConfig={'maxTokens': 20, 'temperature': 0.1}
)
print('✅ Bedrock API accessible')
print(f\"Model response: {response['output']['message']['content'][0]['text'][:50]}...\")
"

# Expected: Success with model response
```

### 8. Show Pod Logs (Optional, 30 seconds)
```bash
# Show recent logs including startup
kubectl logs -n triage-dev deployment/ticket-triage --tail=50 | grep -E "(INFO|bedrock|credentials)"

# Look for:
# - "Initializing LLM client provider=bedrock"
# - "Found credentials from IAM Role: liora-triage-bedrock-role"
# - "Agent initialized successfully"
```

---

## Key Demo Highlights

### Architecture
- **Platform:** AWS EC2 (m6i.xlarge, 4 vCPU / 16 GiB, eu-west-1)
- **Orchestration:** k3s v1.36.5 (lightweight Kubernetes with Traefik)
- **Container:** GHCR-hosted image (built by GitHub Actions, Trivy-scanned)
- **Namespace:** triage-dev (isolated from future PROD)

### AI Stack
- **LLM:** Amazon Bedrock Nova Micro (serverless, IAM-authenticated)
- **Embeddings:** E5-large multilingual (1024-dim, 560M params)
- **Vector DB:** LanceDB (3,206 reference ticket embeddings)
- **Metadata:** DuckDB (26 MB evaluation repository)

### Security
- ✅ IAM instance role (no static AWS keys)
- ✅ Non-root container (UID 1000)
- ✅ Read-only data volumes (LanceDB, DuckDB)
- ✅ Resource limits enforced (1.5 CPU / 4 GiB memory)
- ✅ No public ingress (ClusterIP service only)

### Performance
- **Response time:** 0.8-1.1 seconds (P50: ~1.0s)
- **Memory usage:** ~1 GB RSS (model loaded)
- **CPU usage:** <10m idle, bursts to 500m during inference
- **Success rate:** 100% (9/9 test tickets)
- **Restart count:** 0 (stable since deployment)

### Multilingual Support
- ✅ English, German, Spanish tested
- ✅ Proper topic/urgency classification across languages
- ✅ E5-large embeddings enable semantic search in any language

---

## Backup Tickets (If Time Permits)

### English High-Urgency Claim
```bash
curl -X POST http://localhost:8000/triage \
  -H "Content-Type: application/json" \
  -d '{
    "ticket_id": "DEMO-URGENT-001",
    "subject": "House fire - total loss - need immediate assistance",
    "body": "Our house caught fire last night and we have lost everything. We need emergency housing assistance immediately."
  }' | jq '{topic, urgency, next_action, confidence}'
```

### Spanish Coverage Inquiry
```bash
curl -X POST http://localhost:8000/triage \
  -H "Content-Type: application/json" \
  -d '{
    "ticket_id": "DEMO-INFO-ES-001",
    "subject": "Información sobre cobertura de viaje",
    "body": "Hola, estoy planeando un viaje a Japón y quiero confirmar si mi póliza cubre emergencias médicas en el extranjero."
  }' | jq '{topic, urgency, next_action, confidence}'
```

---

## Troubleshooting (If Issues Arise)

### Pod Not Ready
```bash
kubectl get pods -n triage-dev
kubectl describe pod -n triage-dev <pod-name>
kubectl logs -n triage-dev <pod-name> --tail=100
```

### Port-Forward Fails
```bash
# Kill any existing port-forwards
pkill -f "port-forward.*8000"

# Verify service exists
kubectl get svc -n triage-dev

# Try again
kubectl port-forward -n triage-dev svc/ticket-triage 8000:8000
```

### Connection Refused
```bash
# Check pod is actually ready
kubectl get pods -n triage-dev

# Check readiness endpoint from inside cluster
kubectl exec -n triage-dev deployment/ticket-triage -- \
  curl -s http://localhost:8000/ready
```

---

## Post-Demo Cleanup
```bash
# Stop any port-forwards
pkill -f "port-forward.*8000"

# Optional: Check final resource usage
kubectl top pod -n triage-dev

# Optional: Save metrics snapshot
kubectl exec -n triage-dev deployment/ticket-triage -- \
  curl -s http://localhost:8000/metrics > /tmp/demo_metrics.txt
```

---

## Demo Success Criteria
- ✅ Cluster and pod status shown (healthy)
- ✅ At least 1 ticket processed successfully
- ✅ Bedrock configuration visible
- ✅ IAM authentication confirmed
- ✅ Metrics endpoint accessible
- ✅ Multilingual capability demonstrated
- ✅ Sub-2-second response time achieved

**Estimated Demo Time:** 8-10 minutes (with buffer for questions)
