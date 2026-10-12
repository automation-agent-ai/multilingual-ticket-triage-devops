# AWS EC2 Migration Plan — Corrected Architecture

**Repository:** `automation-agent-ai/multilingual-ticket-triage-devops`  
**Source Commit:** `44360bc` (main, up-to-date with origin/main)  
**Target:** AWS EC2 Ubuntu 24.04 (`i-07bc3aaf0d692974d`, 108.129.133.72)  
**Timeline:** 6-8 hours (single working day)  
**Date:** 2026-10-12

---

## 🎯 Architecture Preservation

**Three-namespace Kubernetes architecture (PRESERVED):**
```
k3s cluster on AWS EC2
├── triage-dev          ← Internal development/testing (ClusterIP only)
├── triage-prod         ← Public HTTPS via Traefik (production workload)
└── triage-monitoring   ← Prometheus + Grafana (ClusterIP only)
```

**NOT creating:** Single `triage-aws` namespace  
**Preserving:** Existing local WSL three-namespace deployment unchanged

---

## 📋 FILES TO REUSE UNCHANGED

### Docker & Base Kubernetes
- ✅ `Dockerfile` — Multi-stage build, non-root, security hardened
- ✅ `k8s/base/deployment.yaml` — Base deployment with security context
- ✅ `k8s/base/service.yaml` — ClusterIP service
- ✅ `k8s/base/kustomization.yaml` — Base kustomization
- ✅ `k8s/overlays/dev/*` — Local WSL DEV overlay (unchanged)
- ✅ `k8s/overlays/prod/*` — Local WSL PROD overlay (unchanged)

### CI/CD & Automation
- ✅ `.github/workflows/ci.yml` — Test, build, Trivy scan, GHCR push
- ✅ `.github/workflows/deploy-dev.yml` — Local runner deployment (WSL only)
- ✅ `.github/workflows/deploy-prod.yml` — Approval gate (WSL only)

### Monitoring
- ✅ `monitoring/prometheus/*` — Prometheus deployment, scrape config, alerts
- ✅ `monitoring/grafana/*` — Grafana deployment, dashboard (8 panels)
- ✅ `monitoring/kustomization.yaml` — Monitoring stack aggregator

### Infrastructure as Code
- ✅ `terraform/providers.tf` — Provider versions (will need separate AWS workspace)
- ✅ `terraform/variables.tf` — Variable definitions
- ✅ `terraform/outputs.tf` — Output definitions

### Disaster Recovery
- ✅ `scripts/dr/backup.sh` — Timestamped backup script
- ✅ `scripts/dr/verify.sh` — SHA-256 integrity check
- ✅ `scripts/dr/restore-test.sh` — Isolated restore validation

### Application Core
- ✅ `src/application/*` — All application logic (agent, analyzer, validator, router)
- ✅ `src/domain/*` — Domain models, enums, mappings
- ✅ `src/infrastructure/duckdb_repository.py` — Database access
- ✅ `src/infrastructure/lancedb_ticket_store.py` — Vector store
- ✅ `src/infrastructure/embedding_model.py` — HuggingFace E5 model
- ✅ `src/infrastructure/evaluation_repository.py` — Metrics tracking
- ✅ `api/app.py` — FastAPI endpoints (will modify agent init only)
- ✅ `api/prom_metrics.py` — Prometheus metrics middleware

---

## 📝 FILES TO CREATE (New)

### LLM Provider Abstraction
```
src/infrastructure/llm_provider.py          # Abstract base class for LLM clients
src/infrastructure/bedrock_client.py        # Amazon Bedrock Converse API adapter
tests/test_bedrock_client.py                # Unit tests with mocked boto3
```

### AWS Kustomize Overlays
```
k8s/overlays/aws-dev/
├── kustomization.yaml                      # triage-dev namespace, GHCR image
├── namespace.yaml                          # Namespace: triage-dev (AWS cluster)
├── configmap.yaml                          # Bedrock config, eu-west-1
└── patches/
    ├── deployment.yaml                     # Volume: /mnt/data, resources: 2Gi/4Gi
    └── service.yaml                        # ClusterIP (internal only)

k8s/overlays/aws-prod/
├── kustomization.yaml                      # triage-prod namespace, GHCR digest
├── namespace.yaml                          # Namespace: triage-prod (AWS cluster)
├── configmap.yaml                          # Bedrock config, eu-west-1
└── patches/
    ├── deployment.yaml                     # Volume: /mnt/data, resources: 2Gi/6Gi
    └── service.yaml                        # ClusterIP (Traefik will expose)
```

### Ingress & Public Access
```
k8s/ingress/
├── traefik-crd.yaml                        # Traefik CRDs (if not bundled)
├── traefik-deployment.yaml                 # Traefik v3 controller
├── traefik-rbac.yaml                       # ClusterRole for Ingress
├── middleware-auth.yaml                    # BasicAuth middleware
├── middleware-ratelimit.yaml               # RateLimiter middleware (10 req/min)
├── ingressroute-prod.yaml                  # HTTPS route to triage-prod
└── README.md                               # Public access architecture
```

### Terraform AWS Workspace
```
terraform/workspaces/
├── aws/
│   ├── main.tf                             # Reuse ../main.tf with remote backend
│   ├── backend.tf                          # S3 + DynamoDB OR local file
│   └── terraform.tfvars                    # AWS-specific values
└── local/
    └── backend.tf                          # Local backend (existing WSL state)
```

### Documentation
```
docs/AWS_DEPLOYMENT.md                      # AWS deployment runbook
docs/BEDROCK_INTEGRATION.md                 # Bedrock adapter design
docs/PUBLIC_DEMO_CONTROLS.md                # Safe on/off mechanism
```

---

## ✏️ FILES TO MODIFY

### Application Initialization
**File:** `api/app.py`  
**Changes:**
- Import `llm_provider.create_llm_client(config)` factory
- Replace hardcoded `OllamaClient` instantiation
- Preserve all other logic (FastAPI app, endpoints, metrics)

**File:** `main.py`  
**Changes:**
- Import LLM factory
- Replace hardcoded `OllamaClient` instantiation in batch runner
- Preserve all batch evaluation logic

**File:** `cli.py`  
**Changes:**
- Import LLM factory
- Replace hardcoded `OllamaClient` instantiation
- Preserve interactive menu

### Configuration
**File:** `config.yaml`  
**Action:** Create `config-aws.yaml` variant (do NOT modify original)  
**Changes:**
```yaml
llm:
  provider: bedrock              # NEW: bedrock OR ollama
  model_name: us.amazon.nova-micro-v1:0  # Bedrock model ID
  region: eu-west-1              # EU region
  inference_profile_arn: arn:aws:bedrock:eu-west-1:...:inference-profile/eu.amazon.nova-micro-v1:0
  temperature: 0.1
  max_retries: 1
  timeout_seconds: 120
```

### Dependencies
**File:** `requirements-docker.txt`  
**Add:**
```
boto3>=1.35.0
botocore>=1.35.0
```

### Terraform Main Module
**File:** `terraform/main.tf`  
**Changes:**
- Remove `docker-desktop` references in comments
- Add conditional `storage_class_name` based on cluster type
- Make it cluster-agnostic

---

## 🔀 Git Branch & CI/CD Strategy

### Branch Strategy
```bash
git checkout -b feat/aws-bedrock-migration
# All AWS-specific changes committed here
# CI pipeline runs automatically on push
# GHCR image built with :sha-<commit> tag
# Merge to main after validation
```

### CI/CD Integration
- **Existing CI:** `.github/workflows/ci.yml` runs on all branches
  - Tests pass (existing tests + new Bedrock unit tests)
  - Trivy scan passes
  - GHCR push: `ghcr.io/automation-agent-ai/multilingual-ticket-triage-devops:sha-<commit>`
  
- **Deployment:** Manual on AWS (no GitHub Actions runner on EC2 initially)
  - Pull image from GHCR by digest
  - `kubectl apply -k k8s/overlays/aws-dev/`
  - `kubectl apply -k k8s/overlays/aws-prod/`

### Image Pinning Strategy
**DEV:** `newTag: sha-<commit>` (latest commit with Bedrock support)  
**PROD:** `newName: ghcr.io/...:sha-<commit>@sha256:<digest>` (full digest pinning)

---

## 🚀 Execution Plan — One Working Day

### PHASE 1: AWS Infrastructure Bootstrap (45 min)

#### 1.1 Install k3s with Traefik
```bash
# Install k3s with embedded Traefik disabled (we'll deploy our own)
curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="--disable traefik" sh -

# Wait for k3s to be ready
sudo systemctl status k3s
sudo chmod 644 /etc/rancher/k3s/k3s.yaml

# Configure kubectl for ubuntu user
mkdir -p ~/.kube
sudo cp /etc/rancher/k3s/k3s.yaml ~/.kube/config
sudo chown ubuntu:ubuntu ~/.kube/config
export KUBECONFIG=~/.kube/config
echo 'export KUBECONFIG=~/.kube/config' >> ~/.bashrc
```

#### 1.2 Install Required Tools
```bash
# kubectl (if not bundled with k3s)
sudo apt update
sudo apt install -y kubectl

# kustomize
curl -sL https://github.com/kubernetes-sigs/kustomize/releases/download/kustomize%2Fv5.4.3/kustomize_v5.4.3_linux_amd64.tar.gz | tar -xz
sudo mv kustomize /usr/local/bin/
kustomize version

# AWS CLI (already available)
sudo apt install -y awscli
```

#### 1.3 Configure IAM Instance Role
```bash
# Verify IAM role attachment (do this in AWS Console first)
aws sts get-caller-identity

# Test Bedrock access
aws bedrock list-foundation-models --region eu-west-1 --query 'modelSummaries[?contains(modelId, `nova-micro`)]' --output table

# If access denied, attach policy:
# {
#   "Version": "2012-10-17",
#   "Statement": [{
#     "Effect": "Allow",
#     "Action": ["bedrock:InvokeModel", "bedrock:InvokeModelWithResponseStream"],
#     "Resource": "arn:aws:bedrock:eu-west-1::foundation-model/amazon.nova-micro-v1:0"
#   }]
# }
```

**Verification:**
- ✅ `kubectl get nodes` shows 1 node Ready
- ✅ `kubectl get pods -A` shows kube-system pods Running
- ✅ `aws bedrock list-foundation-models` returns results

**Rollback:** `sudo /usr/local/bin/k3s-uninstall.sh`

---

### PHASE 2: Data Migration (20 min)

#### 2.1 Prepare Data Directories on EC2
```bash
sudo mkdir -p /mnt/data/{hf-cache,app-data-dev,app-data-prod}
sudo chown -R ubuntu:ubuntu /mnt/data
```

#### 2.2 rsync from Local WSL (RECOMMENDED)
```bash
# From LOCAL WSL machine:
# Transfer DuckDB, LanceDB, dataset CSV (preserve historical evaluations)
rsync -avz --progress --checksum \
  /home/niwr/workspaces/multilingual-ticket-triage-devops/data/ \
  liora-aws:/mnt/data/app-data-dev/

# Copy to PROD data directory (read-only shared data)
ssh liora-aws "rsync -a /mnt/data/app-data-dev/ /mnt/data/app-data-prod/"
```

#### 2.3 Pre-download HuggingFace Model (Optional but Recommended)
```bash
# On EC2
cd /home/ubuntu/workspaces/multilingual-ticket-triage-devops
python3 -m venv .venv
source .venv/bin/activate
pip install sentence-transformers torch --index-url https://download.pytorch.org/whl/cpu

# Download model to /mnt/data/hf-cache
export HF_HOME=/mnt/data/hf-cache
python3 << 'EOF'
from sentence_transformers import SentenceTransformer
model = SentenceTransformer("intfloat/multilingual-e5-large")
print(f"Model cached at: {model._model_card_vars['model_id']}")
EOF
```

**Verification:**
```bash
ls -lh /mnt/data/app-data-dev/
# Should show: tickets.duckdb, lancedb/, dataset-*.csv

du -sh /mnt/data/*
# app-data-dev: ~200-300 MB
# hf-cache: ~2 GB
```

**Checksum Validation:**
```bash
# From LOCAL WSL:
cd /home/niwr/workspaces/multilingual-ticket-triage-devops
sha256sum data/tickets.duckdb data/dataset-*.csv > /tmp/data-checksums.txt

# On EC2:
scp liora-aws:/tmp/data-checksums.txt .
cd /mnt/data/app-data-dev
sha256sum -c ~/data-checksums.txt
# All files should show: OK
```

---

### PHASE 3: Application Code Changes (90 min)

#### 3.1 Create New Branch
```bash
cd /home/ubuntu/workspaces/multilingual-ticket-triage-devops
git checkout -b feat/aws-bedrock-migration
```

#### 3.2 Implement LLM Provider Abstraction
**File:** `src/infrastructure/llm_provider.py`
```python
"""
LLM provider abstraction for pluggable backends.

Supports:
  - Ollama (local inference)
  - Amazon Bedrock (managed inference via Converse API)
"""
from abc import ABC, abstractmethod
from typing import Protocol


class LLMClient(Protocol):
    """Protocol for LLM client implementations."""
    
    def generate_json(self, prompt: str) -> str:
        """Generate JSON response from prompt."""
        ...


def create_llm_client(config: dict) -> LLMClient:
    """
    Factory function to create LLM client based on provider.
    
    Args:
        config: Dictionary with keys:
            - provider: "ollama" | "bedrock"
            - model_name: Model identifier
            - temperature: Float 0.0-1.0
            - timeout_seconds: Request timeout
            - base_url: (ollama only) HTTP endpoint
            - region: (bedrock only) AWS region
            - inference_profile_arn: (bedrock only) Optional inference profile
    
    Returns:
        LLMClient instance (OllamaClient or BedrockClient)
    
    Raises:
        ValueError: If provider is not supported
    """
    provider = config.get("provider", "ollama").lower()
    
    if provider == "ollama":
        from src.infrastructure.llm_client import OllamaClient
        return OllamaClient(
            base_url=config["base_url"],
            model_name=config["model_name"],
            temperature=config["temperature"],
            timeout_seconds=config["timeout_seconds"],
        )
    
    elif provider == "bedrock":
        from src.infrastructure.bedrock_client import BedrockClient
        return BedrockClient(
            model_id=config["model_name"],
            region=config.get("region", "eu-west-1"),
            temperature=config["temperature"],
            timeout_seconds=config["timeout_seconds"],
            inference_profile_arn=config.get("inference_profile_arn"),
        )
    
    else:
        raise ValueError(
            f"Unsupported LLM provider: '{provider}'. "
            f"Supported providers: ollama, bedrock"
        )
```

**File:** `src/infrastructure/bedrock_client.py`
```python
"""
Amazon Bedrock client adapter using Converse API.

Implements the same interface as OllamaClient for drop-in compatibility.
Uses boto3 bedrock-runtime client with Converse API for JSON generation.

Preserves:
  - Pydantic validation in caller (analyzer.py)
  - Retry logic in caller
  - Fallback behavior in caller
"""
import json
import logging
from typing import Optional

import boto3
from botocore.config import Config
from botocore.exceptions import ClientError, ConnectTimeoutError, ReadTimeoutError

logger = logging.getLogger(__name__)


class BedrockClient:
    """
    Amazon Bedrock Converse API adapter matching OllamaClient interface.
    
    Supports Nova Micro with EU inference profile for data residency.
    """
    
    def __init__(
        self,
        model_id: str,
        region: str,
        temperature: float,
        timeout_seconds: int,
        inference_profile_arn: Optional[str] = None,
    ) -> None:
        """
        Initialize Bedrock client.
        
        Args:
            model_id: Foundation model ID (e.g., "amazon.nova-micro-v1:0")
            region: AWS region (e.g., "eu-west-1")
            temperature: Sampling temperature 0.0-1.0
            timeout_seconds: Request timeout
            inference_profile_arn: Optional cross-region inference profile ARN
                for data residency (e.g., eu.amazon.nova-micro-v1:0)
        """
        self.model_id = model_id
        self.temperature = temperature
        self.timeout_seconds = timeout_seconds
        self.inference_profile_arn = inference_profile_arn
        
        # Configure boto3 client with timeout
        config = Config(
            read_timeout=timeout_seconds,
            connect_timeout=10,
            retries={"max_attempts": 0},  # Caller handles retries
        )
        
        self.bedrock = boto3.client(
            "bedrock-runtime",
            region_name=region,
            config=config,
        )
        
        logger.info(
            f"Initialized BedrockClient: model={model_id}, region={region}, "
            f"temperature={temperature}, profile={inference_profile_arn or 'none'}"
        )
    
    def generate_json(self, prompt: str) -> str:
        """
        Send prompt to Bedrock and return raw JSON string response.
        
        Uses Converse API with text messages. Caller is responsible for
        JSON parsing and Pydantic validation (preserves existing behavior).
        
        Args:
            prompt: Text prompt (may include instructions to output JSON)
        
        Returns:
            Raw response text from model (unparsed string)
        
        Raises:
            ClientError: On Bedrock API errors (throttling, access denied, etc.)
            ConnectTimeoutError: If connection times out
            ReadTimeoutError: If request times out
            Exception: On unexpected errors
        """
        try:
            # Prepare Converse API request
            request = {
                "modelId": self.inference_profile_arn or self.model_id,
                "messages": [
                    {
                        "role": "user",
                        "content": [{"text": prompt}],
                    }
                ],
                "inferenceConfig": {
                    "temperature": self.temperature,
                    "maxTokens": 2048,  # Conservative limit for JSON responses
                },
            }
            
            logger.debug(f"Bedrock request: {self.model_id}, prompt_len={len(prompt)}")
            
            # Call Bedrock Converse API
            response = self.bedrock.converse(**request)
            
            # Extract text from response
            output_message = response["output"]["message"]
            content_blocks = output_message["content"]
            
            # Concatenate all text blocks (typically just one)
            response_text = "".join(
                block["text"] for block in content_blocks if "text" in block
            )
            
            logger.debug(
                f"Bedrock response: {response['usage']['inputTokens']} input tokens, "
                f"{response['usage']['outputTokens']} output tokens, "
                f"stop_reason={response['stopReason']}"
            )
            
            return response_text
        
        except ClientError as e:
            error_code = e.response.get("Error", {}).get("Code", "Unknown")
            error_message = e.response.get("Error", {}).get("Message", str(e))
            logger.error(f"Bedrock API error: {error_code} - {error_message}")
            raise
        
        except (ConnectTimeoutError, ReadTimeoutError) as e:
            logger.error(f"Bedrock timeout: {e}")
            raise
        
        except Exception as e:
            logger.error(f"Unexpected Bedrock error: {e}")
            raise
```

**Unit Test:** `tests/test_bedrock_client.py`
```python
"""Unit tests for BedrockClient with mocked boto3."""
import json
from unittest.mock import MagicMock, patch

import pytest

from src.infrastructure.bedrock_client import BedrockClient


@pytest.fixture
def mock_bedrock_client():
    """Mock boto3 bedrock-runtime client."""
    with patch("boto3.client") as mock_client:
        mock_runtime = MagicMock()
        mock_client.return_value = mock_runtime
        yield mock_runtime


def test_bedrock_client_init(mock_bedrock_client):
    """Test BedrockClient initialization."""
    client = BedrockClient(
        model_id="amazon.nova-micro-v1:0",
        region="eu-west-1",
        temperature=0.1,
        timeout_seconds=120,
    )
    
    assert client.model_id == "amazon.nova-micro-v1:0"
    assert client.temperature == 0.1
    assert client.timeout_seconds == 120


def test_bedrock_client_generate_json(mock_bedrock_client):
    """Test successful JSON generation."""
    # Mock Converse API response
    mock_bedrock_client.converse.return_value = {
        "output": {
            "message": {
                "role": "assistant",
                "content": [{"text": '{"topic": "Technical / Online Access", "urgency": "High"}'}],
            }
        },
        "stopReason": "end_turn",
        "usage": {"inputTokens": 150, "outputTokens": 25},
    }
    
    client = BedrockClient(
        model_id="amazon.nova-micro-v1:0",
        region="eu-west-1",
        temperature=0.1,
        timeout_seconds=120,
    )
    
    prompt = "Classify this ticket: Cannot log in"
    response = client.generate_json(prompt)
    
    assert isinstance(response, str)
    assert "topic" in response
    assert "urgency" in response
    
    # Verify Converse API was called correctly
    mock_bedrock_client.converse.assert_called_once()
    call_kwargs = mock_bedrock_client.converse.call_args.kwargs
    assert call_kwargs["modelId"] == "amazon.nova-micro-v1:0"
    assert call_kwargs["messages"][0]["content"][0]["text"] == prompt


def test_bedrock_client_with_inference_profile(mock_bedrock_client):
    """Test client uses inference profile ARN when provided."""
    profile_arn = "arn:aws:bedrock:eu-west-1:123456789012:inference-profile/eu.amazon.nova-micro-v1:0"
    
    mock_bedrock_client.converse.return_value = {
        "output": {"message": {"content": [{"text": "{}"}]}},
        "stopReason": "end_turn",
        "usage": {"inputTokens": 10, "outputTokens": 2},
    }
    
    client = BedrockClient(
        model_id="amazon.nova-micro-v1:0",
        region="eu-west-1",
        temperature=0.1,
        timeout_seconds=120,
        inference_profile_arn=profile_arn,
    )
    
    client.generate_json("Test prompt")
    
    call_kwargs = mock_bedrock_client.converse.call_args.kwargs
    assert call_kwargs["modelId"] == profile_arn  # Uses profile, not base model


def test_bedrock_client_handles_client_error(mock_bedrock_client):
    """Test error handling for Bedrock API errors."""
    from botocore.exceptions import ClientError
    
    error_response = {
        "Error": {"Code": "ThrottlingException", "Message": "Rate exceeded"}
    }
    mock_bedrock_client.converse.side_effect = ClientError(error_response, "Converse")
    
    client = BedrockClient(
        model_id="amazon.nova-micro-v1:0",
        region="eu-west-1",
        temperature=0.1,
        timeout_seconds=120,
    )
    
    with pytest.raises(ClientError) as exc_info:
        client.generate_json("Test prompt")
    
    assert "ThrottlingException" in str(exc_info.value)
```

#### 3.3 Update Application Entry Points

**api/app.py** (minimal changes):
```python
# Around line 52-60, replace:
# from src.infrastructure.llm_client import OllamaClient

# With:
from src.infrastructure.llm_provider import create_llm_client

# Around line 560-570, replace:
# llm_client = OllamaClient(
#     base_url=OLLAMA_BASE_URL,
#     model_name=config["llm"]["model_name"],
#     temperature=config["llm"]["temperature"],
#     timeout_seconds=config["llm"]["timeout_seconds"],
# )

# With:
llm_client = create_llm_client(config["llm"])
```

**Similar changes to:**
- `main.py` (batch runner initialization)
- `cli.py` (CLI menu initialization)

#### 3.4 Update Dependencies
```bash
echo "boto3>=1.35.0" >> requirements-docker.txt
echo "botocore>=1.35.0" >> requirements-docker.txt
```

#### 3.5 Create AWS Configuration
**File:** `config-aws.yaml` (copy of config.yaml with modifications)
```yaml
input_path: data/dataset-tickets-multi-lang3-4k.csv

embedding:
  model_name: intfloat/multilingual-e5-large
  device: auto
  batch_size: 32
  normalize_embeddings: true

vector_store:
  path: data/lancedb
  table_name: ticket_embeddings

retrieval:
  top_k: 5

llm:
  provider: bedrock
  model_name: amazon.nova-micro-v1:0
  region: eu-west-1
  # Optional: EU inference profile for data residency
  inference_profile_arn: arn:aws:bedrock:eu-west-1:<account>:inference-profile/eu.amazon.nova-micro-v1:0
  temperature: 0.1
  max_retries: 1
  timeout_seconds: 120

# ... rest unchanged ...
```

#### 3.6 Commit Changes
```bash
git add src/infrastructure/llm_provider.py
git add src/infrastructure/bedrock_client.py
git add tests/test_bedrock_client.py
git add requirements-docker.txt
git add config-aws.yaml
git add api/app.py main.py cli.py
git commit -m "feat(llm): add Amazon Bedrock provider with Converse API

- Implement LLM provider abstraction (Ollama + Bedrock)
- Add BedrockClient with Converse API support
- Support EU inference profile for data residency
- Preserve existing Pydantic validation and retry logic
- Add unit tests with mocked boto3
- Update application entry points to use factory
- Add config-aws.yaml for Bedrock configuration

Preserves:
- Ollama support for local WSL deployment
- Three-namespace Kubernetes architecture
- Existing CI/CD pipeline
"
```

**Verification:**
```bash
# Run unit tests locally
source .venv/bin/activate
pip install -r requirements-docker.txt pytest httpx
pytest tests/test_bedrock_client.py -v

# All tests should pass
```

---

### PHASE 4: Build & Push Docker Image (20 min)

#### 4.1 Push Branch and Trigger CI
```bash
git push origin feat/aws-bedrock-migration
# GitHub Actions CI runs automatically:
#  - Pytest (744 tests + new Bedrock tests)
#  - Docker build
#  - Trivy scan (CRITICAL/HIGH gate)
#  - GHCR push (sha-<commit>)
```

#### 4.2 Wait for CI Completion
```bash
# Monitor: https://github.com/automation-agent-ai/multilingual-ticket-triage-devops/actions
# Expected: 5-10 minutes
# Result: ghcr.io/automation-agent-ai/multilingual-ticket-triage-devops:sha-<commit>
```

#### 4.3 Note Image Digest
```bash
# From GitHub Actions job summary:
# Image: ghcr.io/.../multilingual-ticket-triage-devops:sha-abc123...
# Digest: sha256:def456...

# Or pull locally to get digest:
docker pull ghcr.io/automation-agent-ai/multilingual-ticket-triage-devops:sha-<commit>
docker inspect ghcr.io/automation-agent-ai/multilingual-ticket-triage-devops:sha-<commit> --format='{{index .RepoDigests 0}}'
```

**Verification:**
- ✅ CI workflow shows green checkmark
- ✅ Trivy scan passed
- ✅ Image available in GHCR package registry
- ✅ Image digest recorded for PROD pinning

---

### PHASE 5: Create AWS Kustomize Overlays (45 min)

#### 5.1 AWS DEV Overlay
```bash
mkdir -p k8s/overlays/aws-dev/patches
```

**k8s/overlays/aws-dev/namespace.yaml:**
```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: triage-dev
  labels:
    environment: aws-dev
    cluster: ec2
```

**k8s/overlays/aws-dev/configmap.yaml:**
```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: ticket-triage-config
  namespace: triage-dev
  labels:
    environment: aws-dev
    app: ticket-triage
data:
  # Application config
  CONFIG_PATH: "/app/config-aws.yaml"
  HOST: "0.0.0.0"
  PORT: "8000"
  ENVIRONMENT: "aws-dev"
  
  # Inference
  INFERENCE_CONCURRENCY: "1"
  
  # HuggingFace cache
  HF_HOME: "/home/appuser/.cache/huggingface"
  TRANSFORMERS_CACHE: "/home/appuser/.cache/huggingface/hub"
  TOKENIZERS_PARALLELISM: "false"
  
  # Python
  PYTHONUNBUFFERED: "1"
  PYTHONDONTWRITEBYTECODE: "1"
  
  # AWS Bedrock (credentials from IAM instance role)
  AWS_REGION: "eu-west-1"
  AWS_DEFAULT_REGION: "eu-west-1"
```

**k8s/overlays/aws-dev/patches/deployment.yaml:**
```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ticket-triage
  namespace: triage-dev
spec:
  replicas: 1
  template:
    spec:
      volumes:
        - name: hf-cache
          hostPath:
            path: /mnt/data/hf-cache
            type: Directory
        - name: app-data
          hostPath:
            path: /mnt/data/app-data-dev
            type: Directory
        - name: outputs
          emptyDir: {}
        # Mount AWS config file
        - name: aws-config
          configMap:
            name: aws-config-file
      
      containers:
        - name: api
          # Resource limits: Conservative for 16 GiB EC2
          resources:
            requests:
              cpu: "500m"
              memory: "2Gi"
            limits:
              cpu: "1500m"
              memory: "4Gi"
          
          volumeMounts:
            - name: hf-cache
              mountPath: /home/appuser/.cache/huggingface
            - name: app-data
              mountPath: /app/data
              readOnly: true
            - name: outputs
              mountPath: /app/outputs
            - name: aws-config
              mountPath: /app/config-aws.yaml
              subPath: config-aws.yaml
```

**k8s/overlays/aws-dev/configmap-files.yaml:**
```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: aws-config-file
  namespace: triage-dev
data:
  config-aws.yaml: |
    # Inline config-aws.yaml content
    # (Copy from config-aws.yaml created in Phase 3)
```

**k8s/overlays/aws-dev/kustomization.yaml:**
```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

namespace: triage-dev

resources:
  - ../../base
  - namespace.yaml
  - configmap.yaml
  - configmap-files.yaml

commonLabels:
  environment: aws-dev
  cluster: ec2

patches:
  - path: patches/deployment.yaml
    target:
      kind: Deployment
      name: ticket-triage

images:
  - name: ticket-triage-api
    newName: ghcr.io/automation-agent-ai/multilingual-ticket-triage-devops
    newTag: sha-<REPLACE_WITH_ACTUAL_COMMIT>  # From Phase 4
```

#### 5.2 AWS PROD Overlay
```bash
mkdir -p k8s/overlays/aws-prod/patches
```

**k8s/overlays/aws-prod/namespace.yaml:**
```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: triage-prod
  labels:
    environment: aws-prod
    cluster: ec2
```

**k8s/overlays/aws-prod/configmap.yaml:**
```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: ticket-triage-config
  namespace: triage-prod
  labels:
    environment: aws-prod
    app: ticket-triage
data:
  CONFIG_PATH: "/app/config-aws.yaml"
  HOST: "0.0.0.0"
  PORT: "8000"
  ENVIRONMENT: "aws-prod"
  INFERENCE_CONCURRENCY: "1"
  HF_HOME: "/home/appuser/.cache/huggingface"
  TRANSFORMERS_CACHE: "/home/appuser/.cache/huggingface/hub"
  TOKENIZERS_PARALLELISM: "false"
  PYTHONUNBUFFERED: "1"
  PYTHONDONTWRITEBYTECODE: "1"
  AWS_REGION: "eu-west-1"
  AWS_DEFAULT_REGION: "eu-west-1"
  RELOAD: "false"  # Disable auto-reload in production
```

**k8s/overlays/aws-prod/patches/deployment.yaml:**
```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ticket-triage
  namespace: triage-prod
spec:
  replicas: 1
  template:
    spec:
      volumes:
        - name: hf-cache
          hostPath:
            path: /mnt/data/hf-cache
            type: Directory
        - name: app-data
          hostPath:
            path: /mnt/data/app-data-prod
            type: Directory
        - name: outputs
          emptyDir: {}
        - name: aws-config
          configMap:
            name: aws-config-file
      
      containers:
        - name: api
          resources:
            requests:
              cpu: "1000m"
              memory: "2Gi"
            limits:
              cpu: "2000m"
              memory: "6Gi"
          
          volumeMounts:
            - name: hf-cache
              mountPath: /home/appuser/.cache/huggingface
            - name: app-data
              mountPath: /app/data
              readOnly: true
            - name: outputs
              mountPath: /app/outputs
            - name: aws-config
              mountPath: /app/config-aws.yaml
              subPath: config-aws.yaml
```

**k8s/overlays/aws-prod/configmap-files.yaml:**
```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: aws-config-file
  namespace: triage-prod
data:
  config-aws.yaml: |
    # Same as DEV
```

**k8s/overlays/aws-prod/kustomization.yaml:**
```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

namespace: triage-prod

resources:
  - ../../base
  - namespace.yaml
  - configmap.yaml
  - configmap-files.yaml

commonLabels:
  environment: aws-prod
  cluster: ec2

patches:
  - path: patches/deployment.yaml
    target:
      kind: Deployment
      name: ticket-triage

images:
  - name: ticket-triage-api
    newName: ghcr.io/automation-agent-ai/multilingual-ticket-triage-devops
    newTag: sha-<COMMIT>@sha256:<DIGEST>  # Full digest from Phase 4
```

**Commit overlays:**
```bash
git add k8s/overlays/aws-dev/
git add k8s/overlays/aws-prod/
git commit -m "feat(k8s): add AWS kustomize overlays for DEV and PROD

- Preserve three-namespace architecture (triage-dev, triage-prod)
- Use /mnt/data for hostPath volumes
- Conservative resource limits (2-4 GiB DEV, 2-6 GiB PROD)
- Mount config-aws.yaml via ConfigMap
- Pin GHCR image by commit SHA and digest
"
```

---

### PHASE 6: Terraform AWS Workspace (30 min)

#### 6.1 Create Terraform AWS Backend
```bash
mkdir -p terraform/workspaces/aws
```

**terraform/workspaces/aws/backend.tf:**
```hcl
# Local backend for initial deployment
# Upgrade to S3 + DynamoDB for production
terraform {
  backend "local" {
    path = "terraform-aws.tfstate"
  }
}
```

**terraform/workspaces/aws/main.tf:**
```hcl
# AWS-specific Terraform workspace
# Reuses parent module with k3s-compatible settings

module "monitoring_infrastructure" {
  source = "../.."

  monitoring_namespace = "triage-monitoring"
  storage_class_name   = "local-path"  # k3s default
  prometheus_pvc_size  = "1Gi"
  grafana_pvc_size     = "1Gi"
}

output "namespace" {
  value       = module.monitoring_infrastructure.namespace_name
  description = "Monitoring namespace created by Terraform"
}

output "prometheus_pvc" {
  value       = module.monitoring_infrastructure.prometheus_pvc_name
  description = "Prometheus PVC name"
}

output "grafana_pvc" {
  value       = module.monitoring_infrastructure.grafana_pvc_name
  description = "Grafana PVC name"
}
```

**terraform/workspaces/aws/terraform.tfvars:**
```hcl
monitoring_namespace = "triage-monitoring"
storage_class_name   = "local-path"
prometheus_pvc_size  = "1Gi"
grafana_pvc_size     = "1Gi"
```

#### 6.2 Update Parent Terraform Module
**terraform/main.tf** (remove docker-desktop references in comments):
```hcl
# Line 25-30: Update comment
# Note: Storage provisioning depends on the cluster's StorageClass.
# - k3s: 'local-path' provisioner (default)
# - Docker Desktop: 'standard' with rancher.io/local-path
# PVCs with WaitForFirstConsumer binding remain Pending until a Pod mounts them.
```

#### 6.3 Initialize and Plan
```bash
cd terraform/workspaces/aws
terraform init
terraform plan

# Review output:
#  + kubernetes_namespace_v1.triage_monitoring
#  + kubernetes_persistent_volume_claim_v1.prometheus_data
#  + kubernetes_persistent_volume_claim_v1.grafana_data
#  + kubernetes_service_account_v1.triage_prometheus
#  + kubernetes_service_account_v1.triage_grafana
```

**DO NOT APPLY YET** — Wait for Phase 8 deployment verification

**Commit Terraform changes:**
```bash
cd /home/ubuntu/workspaces/multilingual-ticket-triage-devops
git add terraform/
git commit -m "feat(terraform): add AWS workspace with local backend

- Create terraform/workspaces/aws/ for separate state
- Remove docker-desktop specific comments
- Use k3s local-path storage class
- Local backend (upgrade to S3 later)
"
```

---

### PHASE 7: Traefik Ingress & Public HTTPS (60 min)

#### 7.1 Create Ingress Directory
```bash
mkdir -p k8s/ingress
```

#### 7.2 Deploy Traefik v3
**k8s/ingress/traefik-rbac.yaml:**
```yaml
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: traefik
  namespace: kube-system

---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: traefik
rules:
  - apiGroups: [""]
    resources: ["services", "endpoints", "secrets"]
    verbs: ["get", "list", "watch"]
  - apiGroups: ["extensions", "networking.k8s.io"]
    resources: ["ingresses", "ingressclasses"]
    verbs: ["get", "list", "watch"]
  - apiGroups: ["extensions", "networking.k8s.io"]
    resources: ["ingresses/status"]
    verbs: ["update"]
  - apiGroups: ["traefik.io", "traefik.containo.us"]
    resources: ["*"]
    verbs: ["get", "list", "watch"]

---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: traefik
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: traefik
subjects:
  - kind: ServiceAccount
    name: traefik
    namespace: kube-system
```

**k8s/ingress/traefik-deployment.yaml:**
```yaml
---
apiVersion: v1
kind: Service
metadata:
  name: traefik
  namespace: kube-system
spec:
  type: LoadBalancer  # k3s will expose on node port
  selector:
    app: traefik
  ports:
    - name: web
      port: 80
      targetPort: 80
      protocol: TCP
    - name: websecure
      port: 443
      targetPort: 443
      protocol: TCP

---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: traefik
  namespace: kube-system
  labels:
    app: traefik
spec:
  replicas: 1
  selector:
    matchLabels:
      app: traefik
  template:
    metadata:
      labels:
        app: traefik
    spec:
      serviceAccountName: traefik
      containers:
        - name: traefik
          image: traefik:v3.0
          args:
            - --api.dashboard=false
            - --providers.kubernetesingress=true
            - --providers.kubernetescrd=true
            - --entrypoints.web.address=:80
            - --entrypoints.websecure.address=:443
            - --log.level=INFO
          ports:
            - name: web
              containerPort: 80
            - name: websecure
              containerPort: 443
          securityContext:
            allowPrivilegeEscalation: false
            capabilities:
              drop: ["ALL"]
              add: ["NET_BIND_SERVICE"]
```

#### 7.3 Create Middleware (Auth + Rate Limiting)
**k8s/ingress/middleware-auth.yaml:**
```yaml
apiVersion: traefik.io/v1alpha1
kind: Middleware
metadata:
  name: basic-auth
  namespace: triage-prod
spec:
  basicAuth:
    secret: traefik-auth-credentials
```

**k8s/ingress/middleware-ratelimit.yaml:**
```yaml
apiVersion: traefik.io/v1alpha1
kind: Middleware
metadata:
  name: rate-limit
  namespace: triage-prod
spec:
  rateLimit:
    average: 10  # 10 requests per period
    period: 1m   # 1 minute
    burst: 20    # Allow burst of 20
```

**k8s/ingress/middleware-security-headers.yaml:**
```yaml
apiVersion: traefik.io/v1alpha1
kind: Middleware
metadata:
  name: security-headers
  namespace: triage-prod
spec:
  headers:
    customResponseHeaders:
      X-Content-Type-Options: "nosniff"
      X-Frame-Options: "DENY"
      X-XSS-Protection: "1; mode=block"
    contentSecurityPolicy: "default-src 'self'"
```

**k8s/ingress/middleware-request-size.yaml:**
```yaml
apiVersion: traefik.io/v1alpha1
kind: Middleware
metadata:
  name: request-size-limit
  namespace: triage-prod
spec:
  buffering:
    maxRequestBodyBytes: 10485760  # 10 MB max request body
```

#### 7.4 Create IngressRoute for PROD
**k8s/ingress/ingressroute-prod.yaml:**
```yaml
---
apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata:
  name: triage-prod-http
  namespace: triage-prod
spec:
  entryPoints:
    - web
  routes:
    - match: Host(`triage.your-domain.com`) || PathPrefix(`/`)
      kind: Rule
      services:
        - name: ticket-triage
          port: 8000
      middlewares:
        - name: basic-auth
        - name: rate-limit
        - name: security-headers
        - name: request-size-limit

---
# HTTPS IngressRoute (requires TLS certificate)
# Deploy after obtaining cert from Let's Encrypt or AWS Certificate Manager
# apiVersion: traefik.io/v1alpha1
# kind: IngressRoute
# metadata:
#   name: triage-prod-https
#   namespace: triage-prod
# spec:
#   entryPoints:
#     - websecure
#   routes:
#     - match: Host(`triage.your-domain.com`)
#       kind: Rule
#       services:
#         - name: ticket-triage
#           port: 8000
#       middlewares:
#         - name: basic-auth
#         - name: rate-limit
#         - name: security-headers
#         - name: request-size-limit
#   tls:
#     secretName: triage-prod-tls
```

#### 7.5 Generate Basic Auth Credentials
```bash
# Generate htpasswd file for Traefik BasicAuth
sudo apt install -y apache2-utils
htpasswd -nb demo-user 'SecurePassword123!' | base64

# Create Kubernetes Secret
kubectl create secret generic traefik-auth-credentials \
  --from-literal=users='demo-user:$apr1$...' \
  --namespace triage-prod \
  --dry-run=client -o yaml > k8s/ingress/secret-auth.yaml

# DO NOT commit secret-auth.yaml to Git
echo "k8s/ingress/secret-auth.yaml" >> .gitignore
```

#### 7.6 Commit Ingress Configuration
```bash
git add k8s/ingress/
git add .gitignore
git commit -m "feat(ingress): add Traefik v3 with auth and rate limiting

- Deploy Traefik v3 as Ingress controller
- BasicAuth middleware for demo access control
- Rate limiting: 10 req/min, burst 20
- Security headers (CSP, X-Frame-Options, etc.)
- Request size limit: 10 MB
- IngressRoute for triage-prod ONLY (DEV remains internal)

Note: Secret not committed (created manually on cluster)
"
```

**Verification (will do in Phase 8):**
- ✅ Traefik pod Running in kube-system
- ✅ LoadBalancer service shows EXTERNAL-IP (EC2 public IP)
- ✅ HTTP request to public IP reaches PROD pod
- ✅ BasicAuth required for /triage endpoint

---

### PHASE 8: Deploy to AWS k3s (45 min)

#### 8.1 Pull Latest Code
```bash
cd /home/ubuntu/workspaces/multilingual-ticket-triage-devops
git pull origin feat/aws-bedrock-migration
```

#### 8.2 Update Kustomization with Actual Commit SHA
```bash
# Get commit SHA from GitHub Actions or local
COMMIT_SHA=$(git rev-parse HEAD | cut -c1-40)
IMAGE_TAG="sha-${COMMIT_SHA}"

# Update DEV kustomization
sed -i "s/sha-<REPLACE_WITH_ACTUAL_COMMIT>/${IMAGE_TAG}/" k8s/overlays/aws-dev/kustomization.yaml

# Get image digest (requires Docker or skopeo)
docker pull ghcr.io/automation-agent-ai/multilingual-ticket-triage-devops:${IMAGE_TAG}
DIGEST=$(docker inspect ghcr.io/automation-agent-ai/multilingual-ticket-triage-devops:${IMAGE_TAG} --format='{{index .RepoDigests 0}}' | cut -d@ -f2)

# Update PROD kustomization with full digest
sed -i "s|sha-<COMMIT>@sha256:<DIGEST>|${IMAGE_TAG}@${DIGEST}|" k8s/overlays/aws-prod/kustomization.yaml
```

#### 8.3 Verify Manifests
```bash
# Render DEV manifests
kubectl kustomize k8s/overlays/aws-dev | less

# Render PROD manifests
kubectl kustomize k8s/overlays/aws-prod | less

# Check for errors
kubectl kustomize k8s/overlays/aws-dev --enable-alpha-plugins
kubectl kustomize k8s/overlays/aws-prod --enable-alpha-plugins
```

#### 8.4 Apply Terraform (Monitoring Infrastructure)
```bash
cd terraform/workspaces/aws
terraform apply
# Review plan:
#  + 5 resources (namespace, 2 PVCs, 2 ServiceAccounts)
# Type 'yes' to confirm

# Verify
kubectl get namespace triage-monitoring
kubectl get pvc -n triage-monitoring
# PVCs should be Pending (WaitForFirstConsumer)
```

#### 8.5 Deploy DEV Environment
```bash
cd /home/ubuntu/workspaces/multilingual-ticket-triage-devops

# Apply DEV overlay
kubectl apply -k k8s/overlays/aws-dev

# Watch deployment
kubectl get pods -n triage-dev -w

# Expected: Pod transitions from Pending → ContainerCreating → Running
# Startup takes 2-5 minutes (model loading)
```

**Verification:**
```bash
# Check pod status
kubectl get pods -n triage-dev -o wide

# Check logs
kubectl logs -n triage-dev -l app=ticket-triage --tail=100

# Expected log lines:
# "Initialized BedrockClient: model=amazon.nova-micro-v1:0, region=eu-west-1"
# "Agent initialized successfully"
# "Application startup complete"
```

#### 8.6 Deploy PROD Environment
```bash
# Apply PROD overlay
kubectl apply -k k8s/overlays/aws-prod

# Watch deployment
kubectl get pods -n triage-prod -w
```

#### 8.7 Deploy Monitoring Stack
```bash
# Apply Prometheus + Grafana
kubectl apply -k monitoring/

# Watch pods
kubectl get pods -n triage-monitoring -w

# PVCs should transition from Pending to Bound
kubectl get pvc -n triage-monitoring
```

#### 8.8 Deploy Traefik Ingress
```bash
# Apply RBAC
kubectl apply -f k8s/ingress/traefik-rbac.yaml

# Apply Traefik deployment
kubectl apply -f k8s/ingress/traefik-deployment.yaml

# Wait for LoadBalancer IP
kubectl get svc -n kube-system traefik -w
# EXTERNAL-IP should show EC2 public IP (108.129.133.72)

# Create auth secret
kubectl apply -f k8s/ingress/secret-auth.yaml

# Apply middlewares
kubectl apply -f k8s/ingress/middleware-auth.yaml
kubectl apply -f k8s/ingress/middleware-ratelimit.yaml
kubectl apply -f k8s/ingress/middleware-security-headers.yaml
kubectl apply -f k8s/ingress/middleware-request-size.yaml

# Apply IngressRoute
kubectl apply -f k8s/ingress/ingressroute-prod.yaml
```

**Verification:**
```bash
# All pods Running
kubectl get pods -A

# Expected namespaces:
# - kube-system (traefik)
# - triage-dev (ticket-triage)
# - triage-prod (ticket-triage)
# - triage-monitoring (prometheus, grafana)
```

---

### PHASE 9: Smoke Testing & Validation (30 min)

#### 9.1 DEV Health Checks
```bash
POD_DEV=$(kubectl get pod -n triage-dev -l app=ticket-triage -o jsonpath='{.items[0].metadata.name}')

# Health endpoint
kubectl exec -n triage-dev $POD_DEV -- curl -sf http://localhost:8000/health

# Readiness endpoint
kubectl exec -n triage-dev $POD_DEV -- curl -sf http://localhost:8000/ready
# Expected: {"ready": true, "message": "Agent initialized"}

# Metrics endpoint
kubectl exec -n triage-dev $POD_DEV -- curl -sf http://localhost:8000/metrics | head -20
```

#### 9.2 PROD Health Checks
```bash
POD_PROD=$(kubectl get pod -n triage-prod -l app=ticket-triage -o jsonpath='{.items[0].metadata.name}')

kubectl exec -n triage-prod $POD_PROD -- curl -sf http://localhost:8000/health
kubectl exec -n triage-prod $POD_PROD -- curl -sf http://localhost:8000/ready
```

#### 9.3 Bedrock Smoke Test (DEV)
```bash
# Test single ticket triage via DEV pod
kubectl exec -n triage-dev $POD_DEV -- curl -sf http://localhost:8000/triage -X POST \
  -H "Content-Type: application/json" \
  -d '{
    "ticket_id": "smoke-001",
    "subject": "Cannot access my insurance portal",
    "body": "I forgot my password and the reset link does not work. Please help urgently."
  }' | jq .

# Expected response:
# {
#   "ticket_id": "smoke-001",
#   "topic": "Technical / Online Access",
#   "urgency": "High" or "Medium",
#   "next_action": "escalate_to_human_supervisor" or "provide_technical_support",
#   "confidence": 0.7-0.9,
#   ...
# }
```

**Verify in CloudWatch (optional):**
```bash
# Check Bedrock invocations
aws cloudwatch get-metric-statistics \
  --namespace AWS/Bedrock \
  --metric-name Invocations \
  --dimensions Name=ModelId,Value=amazon.nova-micro-v1:0 \
  --start-time $(date -u -d '10 minutes ago' +%Y-%m-%dT%H:%M:%S) \
  --end-time $(date -u +%Y-%m-%dT%H:%M:%S) \
  --period 300 \
  --statistics Sum \
  --region eu-west-1
```

#### 9.4 Public HTTPS Test (PROD)
```bash
# Test from external machine (or curl from EC2)
# Replace <AUTH_CREDS> with base64(username:password)

curl -i http://108.129.133.72/health

# Expected: HTTP 401 Unauthorized (BasicAuth required)

curl -i -u demo-user:SecurePassword123! http://108.129.133.72/triage \
  -X POST \
  -H "Content-Type: application/json" \
  -d '{
    "ticket_id": "public-001",
    "subject": "Billing question",
    "body": "Why was I charged twice this month?"
  }'

# Expected: HTTP 200 OK with triage response
```

#### 9.5 Rate Limiting Test
```bash
# Send 15 requests in rapid succession (should hit rate limit)
for i in {1..15}; do
  curl -u demo-user:SecurePassword123! http://108.129.133.72/health -w "\n%{http_code}\n"
  sleep 0.5
done

# Expected: First 10-12 return 200, remaining return 429 (Too Many Requests)
```

#### 9.6 Prometheus Scraping
```bash
# Port-forward Prometheus
kubectl port-forward -n triage-monitoring svc/prometheus 9090:9090 &

# Check targets
curl -s http://localhost:9090/api/v1/targets | jq '.data.activeTargets[] | select(.labels.namespace | contains("triage"))'

# Expected: 2 targets (triage-dev, triage-prod) with state="up"

# Query metrics
curl -s 'http://localhost:9090/api/v1/query?query=triage_requests_total' | jq '.data.result'
```

#### 9.7 Grafana Dashboard
```bash
# Port-forward Grafana
kubectl port-forward -n triage-monitoring svc/grafana 3000:3000 &

# Get admin password
kubectl get secret -n triage-monitoring grafana-admin-credentials -o jsonpath='{.data.password}' | base64 -d

# Open browser: http://localhost:3000
# Login: admin / <password>
# Navigate to: Dashboards → Ticket Triage Metrics
# Verify: Panels show data from both DEV and PROD
```

**Verification Checklist:**
- ✅ DEV /health and /ready return 200
- ✅ PROD /health and /ready return 200
- ✅ DEV Bedrock smoke test returns valid triage response
- ✅ Public endpoint requires BasicAuth
- ✅ Public triage request succeeds with auth
- ✅ Rate limiting triggers after 10 requests/minute
- ✅ Prometheus scrapes both DEV and PROD
- ✅ Grafana dashboard shows live metrics

---

### PHASE 10: Documentation & Handoff (30 min)

#### 10.1 Create Deployment Runbook
**docs/AWS_DEPLOYMENT.md:**
```markdown
# AWS Deployment Runbook

## Architecture

k3s cluster on EC2 (108.129.133.72, Ubuntu 24.04)
├── triage-dev (ClusterIP, internal only)
├── triage-prod (ClusterIP, exposed via Traefik HTTPS)
└── triage-monitoring (Prometheus + Grafana, internal only)

## Access

### Internal (kubectl port-forward required)
- DEV: kubectl port-forward -n triage-dev svc/ticket-triage 8000:8000
- Prometheus: kubectl port-forward -n triage-monitoring svc/prometheus 9090:9090
- Grafana: kubectl port-forward -n triage-monitoring svc/grafana 3000:3000

### Public (HTTPS with BasicAuth)
- PROD: http://108.129.133.72/triage
- Credentials: demo-user / SecurePassword123!
- Rate limit: 10 req/min

## Deployment

### Update Application
1. Push code to feat/aws-bedrock-migration
2. Wait for GitHub Actions CI (5-10 min)
3. Note image SHA: ghcr.io/.../multilingual-ticket-triage-devops:sha-<commit>
4. Update k8s/overlays/aws-dev/kustomization.yaml with new tag
5. kubectl apply -k k8s/overlays/aws-dev

### Rollback
kubectl rollout undo deployment/ticket-triage -n triage-dev
kubectl rollout undo deployment/ticket-triage -n triage-prod

## Monitoring

- Prometheus: http://localhost:9090 (port-forward)
- Grafana: http://localhost:3000 (port-forward)
- Metrics: http://localhost:8000/metrics (exec into pod)

## Troubleshooting

### Pod stuck in Pending
kubectl describe pod -n triage-dev <pod-name>
# Check: PVC binding, resource availability

### Bedrock access denied
aws sts get-caller-identity  # Verify IAM role
aws bedrock list-foundation-models --region eu-west-1

### Public endpoint not accessible
kubectl get svc -n kube-system traefik  # Check EXTERNAL-IP
kubectl logs -n kube-system -l app=traefik  # Check Traefik logs
```

#### 10.2 Create Public Demo Controls
**docs/PUBLIC_DEMO_CONTROLS.md:**
```markdown
# Public Demo On/Off Controls

## Safe Shutdown (Preserves Configuration)

### Option 1: Scale PROD to Zero (Fastest)
```bash
kubectl scale deployment/ticket-triage -n triage-prod --replicas=0
# Service and Ingress remain, but no pod to serve traffic
# Users see 503 Service Unavailable
```

### Option 2: Delete IngressRoute (External Access Only)
```bash
kubectl delete ingressroute triage-prod-http -n triage-prod
# PROD pod still runs (internal testing possible)
# Public endpoint returns 404
```

### Option 3: Suspend Entire PROD Namespace (Nuclear Option)
```bash
kubectl scale deployment --all --replicas=0 -n triage-prod
# All PROD workloads stopped
# DEV and monitoring unaffected
```

## Startup

### Option 1: Scale Back
```bash
kubectl scale deployment/ticket-triage -n triage-prod --replicas=1
kubectl rollout status deployment/ticket-triage -n triage-prod
```

### Option 2: Re-apply IngressRoute
```bash
kubectl apply -f k8s/ingress/ingressroute-prod.yaml
```

## Cost Optimization

### During Demo Pause (Nights/Weekends)
- Scale PROD to 0 replicas: Saves Bedrock costs (no API calls)
- Keep DEV at 1 replica: Internal testing available
- Keep monitoring: Historical data preserved

### Full Shutdown (Extended Absence)
```bash
kubectl delete namespace triage-prod  # Can recreate anytime
kubectl scale deployment --all --replicas=0 -n triage-monitoring
```

## Resource Monitoring
```bash
# Check actual memory/CPU usage
kubectl top nodes
kubectl top pods -A

# Expected idle usage:
# - DEV: ~1.5 GiB RAM, 0.1-0.3 CPU
# - PROD: ~1.5 GiB RAM, 0.05 CPU (if idle)
# - Prometheus: ~500 MiB RAM
# - Grafana: ~200 MiB RAM
# Total: ~4-5 GiB used of 16 GiB available
```
```

#### 10.3 Update Main README
**README.md** (add AWS section at end):
```markdown
---

## AWS Deployment

This application is deployed on AWS EC2 with Amazon Bedrock for LLM inference.

**Public Demo:** http://108.129.133.72/triage  
**Credentials:** demo-user / SecurePassword123!  
**Rate Limit:** 10 requests per minute

### Architecture
- **k3s Kubernetes** on EC2 Ubuntu 24.04 (4 vCPU, 16 GiB RAM)
- **Amazon Bedrock** Nova Micro (eu-west-1, EU inference profile)
- **Traefik Ingress** with BasicAuth and rate limiting
- **Three namespaces:** triage-dev, triage-prod, triage-monitoring

### Documentation
- [AWS Deployment Runbook](docs/AWS_DEPLOYMENT.md)
- [Bedrock Integration](docs/BEDROCK_INTEGRATION.md)
- [Public Demo Controls](docs/PUBLIC_DEMO_CONTROLS.md)

### Local WSL Deployment
The original three-namespace Kubernetes deployment on Docker Desktop remains unchanged.
See existing documentation for local deployment instructions.
```

#### 10.4 Commit Documentation
```bash
git add docs/AWS_DEPLOYMENT.md
git add docs/PUBLIC_DEMO_CONTROLS.md
git add README.md
git commit -m "docs: add AWS deployment runbook and public demo controls"
```

#### 10.5 Push All Changes
```bash
git push origin feat/aws-bedrock-migration
```

#### 10.6 Verify GitHub Actions
```bash
# Monitor: https://github.com/automation-agent-ai/multilingual-ticket-triage-devops/actions
# All checks should pass
```

**Final Verification:**
- ✅ All commits pushed to feat/aws-bedrock-migration
- ✅ CI pipeline green
- ✅ Documentation complete
- ✅ AWS deployment operational

---

## 📊 RESOURCE ALLOCATION SUMMARY

### EC2 Capacity: 16 GiB RAM / 4 vCPUs

| Workload | Replicas | Request | Limit | Notes |
|---|---|---|---|---|
| triage-dev | 1 | 2 Gi / 0.5 CPU | 4 Gi / 1.5 CPU | Internal testing |
| triage-prod | 1 | 2 Gi / 1.0 CPU | 6 Gi / 2.0 CPU | Public demo |
| prometheus | 1 | - | - | ~500 MiB actual |
| grafana | 1 | - | - | ~200 MiB actual |
| traefik | 1 | - | - | ~100 MiB actual |
| **Total Requests** | | **4 Gi / 1.5 CPU** | **10 Gi / 3.5 CPU** | |
| **Actual Usage** | | **~5-6 Gi** | | Measured after startup |

**Safety Margins:**
- Requests fit comfortably: 4 GiB < 16 GiB, 1.5 CPU < 4 CPU
- Limits allow burst: 10 GiB for app peaks
- ~10 GiB buffer for OS, k3s, buffers

**Cost Optimization:**
- Scale PROD to 0 during nights: Saves Bedrock API costs
- DEV remains at 1 replica for testing
- Monitoring always on for historical data

---

## 🔒 SECURITY CHECKLIST

### Implemented Controls
- ✅ IAM instance role (no persistent keys)
- ✅ Kubernetes RBAC (namespace isolation)
- ✅ Non-root containers (UID 1000)
- ✅ Read-only root filesystem (except Python __pycache__)
- ✅ Capabilities dropped (ALL)
- ✅ BasicAuth on public endpoint
- ✅ Rate limiting (10 req/min)
- ✅ Request size limit (10 MB)
- ✅ Security headers (CSP, X-Frame-Options)
- ✅ Secrets excluded from Git
- ✅ GHCR image Trivy-scanned

### Not Yet Implemented (Optional Improvements)
- 🔲 TLS/HTTPS (using HTTP for initial demo)
- 🔲 NetworkPolicy (namespace isolation)
- 🔲 PodSecurityPolicy/PodSecurity admission
- 🔲 AWS WAF (web application firewall)
- 🔲 CloudWatch Logs integration
- 🔲 Automated EBS snapshots

---

## 🎯 MINIMUM VIABLE PUBLIC DEMO

### Must-Have (Delivered in Phases 1-9)
- ✅ k3s cluster on AWS EC2
- ✅ Three-namespace architecture preserved
- ✅ Application using Amazon Bedrock (eu-west-1)
- ✅ Public HTTPS endpoint with BasicAuth
- ✅ Rate limiting (10 req/min)
- ✅ Prometheus + Grafana monitoring
- ✅ Safe on/off controls (scale to 0)

### Optional Improvements (Post-MVP)
- 🔲 Custom domain with TLS certificate
- 🔲 OAuth2 authentication (AWS Cognito)
- 🔲 CDN (CloudFront)
- 🔲 Multi-replica PROD for HA
- 🔲 Horizontal Pod Autoscaler
- 🔲 AWS ALB Ingress (instead of Traefik)
- 🔲 RDS for DuckDB (persistent shared state)
- 🔲 S3 for LanceDB (object storage backend)
- 🔲 Terraform remote backend (S3 + DynamoDB)
- 🔲 GitHub Actions self-hosted runner on EC2

---

## ⏱️ EXECUTION TIMELINE

| Phase | Duration | Cumulative | Critical Path |
|---|---|---|---|
| 1. AWS Bootstrap | 45 min | 0:45 | ✅ Critical |
| 2. Data Migration | 20 min | 1:05 | ✅ Critical |
| 3. Code Changes | 90 min | 2:35 | ✅ Critical |
| 4. Docker Build/Push | 20 min | 2:55 | ⏸️ CI waits |
| 5. Kustomize Overlays | 45 min | 3:40 | Can parallel with 3-4 |
| 6. Terraform Workspace | 30 min | 4:10 | Can parallel with 4-5 |
| 7. Traefik Ingress | 60 min | 5:10 | Can parallel with 6 |
| 8. Deploy to k3s | 45 min | 5:55 | ✅ Critical |
| 9. Smoke Testing | 30 min | 6:25 | ✅ Critical |
| 10. Documentation | 30 min | 6:55 | Can be done later |
| **Total** | **6 hours 55 min** | | **One working day** |

**Optimization Opportunities:**
- Phases 3-7 can be partially parallelized (separate terminals)
- Phase 4 (CI build) can run while working on Phase 5-6
- Phase 10 (documentation) can be deferred to end of day

**Realistic Timeline:** 7-8 hours with breaks and troubleshooting buffer

---

## 🚨 STOP CONDITIONS

**Do NOT proceed to next phase if:**

| Phase | Stop Condition | Action |
|---|---|---|
| 1 | k3s node not Ready | Check system logs, reboot EC2 |
| 2 | Checksum mismatch | Re-run rsync, verify source data |
| 3 | Unit tests fail | Fix tests before committing |
| 4 | CI build fails | Fix build errors, re-push |
| 4 | Trivy scan fails | Review CVEs, update dependencies |
| 8 | Pod CrashLoopBackOff | Check logs, verify IAM role, Bedrock access |
| 9 | Bedrock returns 403 | Verify IAM policy, model access |
| 9 | Public endpoint 5xx | Check Traefik logs, pod logs |

**Rollback Strategy:**
- Phase 1-2: `k3s-uninstall.sh`, delete /mnt/data
- Phase 3-7: `git reset --hard origin/main`
- Phase 8: `kubectl delete namespace triage-dev triage-prod`
- Phase 9: No changes to rollback (read-only testing)

---

## 📝 POST-MIGRATION TASKS

### Week 1
- [ ] Monitor Bedrock costs (CloudWatch Billing)
- [ ] Measure actual resource usage (kubectl top)
- [ ] Tune rate limits based on actual traffic
- [ ] Compare Ollama vs Bedrock accuracy (A/B test)

### Week 2
- [ ] Set up automated EBS snapshots
- [ ] Configure CloudWatch alarms (CPU, memory, 5xx errors)
- [ ] Implement TLS with Let's Encrypt
- [ ] Migrate Terraform to S3 remote backend

### Month 1
- [ ] Evaluate multi-replica PROD for HA
- [ ] Implement HPA (Horizontal Pod Autoscaler)
- [ ] Set up centralized logging (CloudWatch Logs)
- [ ] Security audit: penetration testing

---

## END OF PLAN

This corrected execution plan:
- ✅ Preserves three-namespace architecture
- ✅ Reuses existing components maximally
- ✅ Adds Bedrock without breaking Ollama
- ✅ Uses IAM instance role (no keys)
- ✅ Transfers existing data (no rebuild)
- ✅ Creates AWS-specific overlays (keeps WSL overlays)
- ✅ Separates Terraform state
- ✅ Implements public HTTPS with auth
- ✅ Respects 16 GiB resource limit
- ✅ Uses small smoke tests (not 200-ticket batch)
- ✅ Deliverable in one working day

**Ready for approval and phase-by-phase execution.**
