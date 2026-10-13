# Phase 10C — Real Amazon Bedrock Inference Metadata in Swagger

**Date**: October 13, 2026  
**Status**: ✅ Implementation Complete — Awaiting DEV Deployment  
**Commit**: `4216729` on `feat/aws-bedrock-migration`  

---

## OBJECTIVE

Extend the `/triage` API response with real, request-specific Amazon Bedrock inference metadata to provide trustworthy evidence that Nova Micro genuinely processed each request.

---

## IMPLEMENTATION SUMMARY

### 1. Core Changes

**New Pydantic Model** — `InferenceMetadata`:
```python
class InferenceMetadata(BaseModel):
    provider: str                      # "bedrock" or "ollama"
    model: str                         # "eu.amazon.nova-micro-v1:0"
    region: str | None                 # "eu-west-1" (Bedrock only)
    invoked: bool                      # True if inference succeeded
    input_tokens: int | None           # Real token consumption
    output_tokens: int | None          # Real token generation
    latency_ms: int | None             # Real inference latency
    invocation_count: int              # 1 (success) or 2 (with retry)
```

**Extended API Response** — `/triage` now returns:
```json
{
  "ticket_id": "DEMO-001",
  "topic": "Claims / Damage",
  "urgency": "High",
  "confidence": 0.92,
  ...
  "inference": {
    "provider": "bedrock",
    "model": "eu.amazon.nova-micro-v1:0",
    "region": "eu-west-1",
    "invoked": true,
    "input_tokens": 327,
    "output_tokens": 118,
    "latency_ms": 920,
    "invocation_count": 1
  }
}
```

---

### 2. Metadata Extraction Pipeline

**Data Flow**:
```
boto3 Converse API response
  → BedrockClient.generate_json() returns (text, metadata_dict)
    → LocalLLMAnalyzer.analyze() aggregates metadata across retries
      → TicketTriageAgent propagates to TriageResult
        → FastAPI serializes to TicketTriageResponse
          → Public /triage endpoint JSON response
```

**Bedrock Converse Response Structure**:
```python
response = {
    "usage": {
        "inputTokens": 327,
        "outputTokens": 118
    },
    "metrics": {
        "latencyMs": 920  # Optional field
    },
    "ResponseMetadata": {
        "RequestId": "abc-123..."  # Not exposed publicly
    }
}
```

**Defensive Extraction** — `_extract_metadata()`:
- Handles missing `metrics` field (returns `latency_ms: None`)
- Handles missing `usage` field (returns `input_tokens/output_tokens: None`)
- Never raises exceptions on missing fields
- Logs warnings for debugging

---

### 3. Retry Aggregation Logic

When the analyzer retries due to validation failure:

1. **First call** — metadata captured:
   ```python
   {
       "input_tokens": 150,
       "output_tokens": 50,
       "latency_ms": 800,
       "invocation_count": 1
   }
   ```

2. **Retry call** — metadata captured:
   ```python
   {
       "input_tokens": 180,
       "output_tokens": 70,
       "latency_ms": 920
   }
   ```

3. **Aggregated metadata**:
   ```python
   {
       "input_tokens": 330,        # 150 + 180 (sum)
       "output_tokens": 120,       # 50 + 70 (sum)
       "latency_ms": 920,          # max(800, 920)
       "invocation_count": 2       # tracks retry
   }
   ```

**Semantics**:
- **Tokens**: Summed across all calls (reflects actual consumption)
- **Latency**: Maximum observed (worst-case latency)
- **Model/Region**: Same for all calls (verified)
- **Invoked**: True if ANY call succeeded

---

### 4. Files Modified

| File | Change Summary |
|------|---------------|
| `src/domain/models.py` | Added `InferenceMetadata` model, extended `TriageResult` with optional `inference` field |
| `src/infrastructure/bedrock_client.py` | Modified `generate_json()` to return `(text, metadata)` tuple, added `_extract_metadata()` helper |
| `src/infrastructure/llm_client.py` | Modified `generate_json()` to return `(text, metadata)` tuple for OllamaClient |
| `src/application/analyzer.py` | Updated `analyze()` to return `(LLMAnalysis, metadata)` tuple, added aggregation logic |
| `src/application/agent.py` | Imported `InferenceMetadata`, propagated metadata to `TriageResult`, built inference object |
| `src/application/reviewer.py` | Updated to handle tuple return (metadata discarded for reviewer) |
| `api/app.py` | Extended `TicketTriageResponse` with `inference` field, updated `_triage_result_to_response()` |

**Test Files Updated**:
- `tests/test_bedrock_client.py` — 22 tests (added metadata extraction tests)
- `tests/test_llm_client.py` — 5 tests (updated for tuple returns)
- `tests/test_analyzer.py` — 13 tests (added aggregation tests)
- `tests/test_api.py` — 14 tests (added inference field test)

**Total**: 54 passing tests (20 Bedrock + 5 Ollama + 13 Analyzer + 14 API + 2 new)

---

### 5. Backward Compatibility

✅ **All existing API fields preserved**:
- `ticket_id`, `text_snippet`, `topic`, `urgency`, `next_action`
- `confidence`, `missing_info`, `missing_fields`
- `requires_human_review`, `short_note`, `action_result`

✅ **New field is optional**:
- `inference: InferenceMetadata | None = None`
- FastAPI serializes as nullable JSON field
- OpenAPI schema includes the new field

✅ **Classification behavior unchanged**:
- Same prompts, same ontology, same routing logic
- Same validator and human-review rules
- Same simulated action execution

✅ **Local Ollama compatibility maintained**:
- Ollama client returns metadata with `provider: "ollama"`, `model_id: <model>`
- Token counts and latency are `None` (Ollama doesn't provide these)
- Tests still pass for both providers

---

### 6. Security Considerations

**What IS Exposed**:
- Provider name (bedrock/ollama)
- Model/inference profile ID
- AWS region
- Token counts (aggregated)
- Inference latency (milliseconds)
- Invocation count (1 or 2)

**What IS NOT Exposed**:
- AWS Request IDs (logged server-side only)
- IAM credentials or instance role details
- Raw prompts or system instructions
- Full boto3 response metadata
- Customer ticket content in logs

**Rationale**:
- Token usage proves real inference without exposing sensitive details
- Latency is observable externally anyway
- RequestId correlation is for internal debugging only

---

### 7. Testing Evidence

**Unit Tests** — Bedrock client:
```
✅ test_generate_json_returns_full_schema_text
✅ test_metadata_includes_latency_when_present
✅ test_metadata_handles_missing_metrics_gracefully
✅ test_analyzer_retries_malformed_bedrock_json_then_accepts_full_schema
✅ test_analyzer_fallback_when_bedrock_never_satisfies_schema
```

**Aggregation Tests** — Analyzer:
```
✅ test_invalid_json_triggers_retry
   - Verifies invocation_count == 2
   - Verifies input_tokens == 20 (10 + 10)
✅ test_retry_failure_returns_fallback
   - Verifies invocation_count == 2 even with fallback
```

**API Integration Test**:
```
✅ test_inference_metadata_field_in_response
   - Verifies "inference" key exists in /triage response
```

**Full Test Run**:
```bash
pytest tests/test_bedrock_client.py tests/test_llm_client.py \
       tests/test_analyzer.py tests/test_api.py -v

======================== 54 passed in 6.08s =========================
```

---

### 8. Known Limitations

1. **Fake Agent Metadata**: The `FakeTicketTriageAgent` in API tests currently returns `inference: None`. When real agents are tested in DEV, metadata will populate.

2. **Reviewer Metadata Not Exposed**: When the reviewer is enabled, its token usage is not included in the final response. The response shows only the primary analyzer metadata. Reviewer is currently disabled in AWS config.

3. **Multiple Analyzer Calls**: If the analyzer is called multiple times in one request (e.g., by a batch processor), only the last call's metadata is preserved. This is not an issue in the current single-ticket `/triage` endpoint.

4. **Ollama Limited Metadata**: Ollama responses include only provider and model. Token counts and latency are always `None`.

---

### 9. Next Steps — DEV Deployment

**GitHub Actions Build**:
- Push to `feat/aws-bedrock-migration` triggers AWS feature image build
- Image tag: `ghcr.io/automation-agent-ai/multilingual-ticket-triage-devops:aws-sha-4216729<...>`
- Tests run automatically in CI (54 passing)
- Trivy security scan (CRITICAL/HIGH blocking)

**Manual DEV Deployment** (after image available):
```bash
# 1. Update DEV deployment to use new image
kubectl set image deployment/ticket-triage-api \
  ticket-triage-api=ghcr.io/automation-agent-ai/multilingual-ticket-triage-devops:aws-sha-4216729... \
  -n triage-dev

# 2. Wait for rollout
kubectl rollout status deployment/ticket-triage-api -n triage-dev

# 3. Verify pod health
kubectl get pods -n triage-dev

# 4. Test /health
curl http://<dev-internal-ip>:8000/health

# 5. Submit test ticket
curl -X POST http://<dev-internal-ip>:8000/triage \
  -H "Content-Type: application/json" \
  -d '{
    "ticket_id": "PHASE10C-DEV-TEST-001",
    "subject": "Car accident claim",
    "body": "I was in an accident yesterday and need to file a claim urgently."
  }'

# 6. Verify inference metadata in response
# Expected: provider=bedrock, model=eu.amazon.nova-micro-v1:0, region=eu-west-1
# Expected: input_tokens > 0, output_tokens > 0, latency_ms > 0
```

---

### 10. DEV Verification Checklist

Before PROD deployment, verify in DEV:

- [ ] HTTP 200 response from `/triage`
- [ ] `inference` field present in JSON response
- [ ] `inference.provider == "bedrock"`
- [ ] `inference.model == "eu.amazon.nova-micro-v1:0"`
- [ ] `inference.region == "eu-west-1"`
- [ ] `inference.invoked == true`
- [ ] `inference.input_tokens > 0` (realistic value, not hardcoded)
- [ ] `inference.output_tokens > 0` (realistic value, not hardcoded)
- [ ] `inference.latency_ms > 0` (realistic latency, e.g., 500-2000ms)
- [ ] `inference.invocation_count == 1` (or 2 if retry occurred)
- [ ] Classification fields (topic, urgency) are dynamically generated
- [ ] Different tickets produce different token counts
- [ ] No AWS RequestId or credentials in public response

---

### 11. PROD Deployment Plan

**Prerequisites**:
1. DEV verification complete (all checklist items ✅)
2. Real Bedrock token usage confirmed (not test stub)
3. Multiple test tickets show varying metadata
4. No security concerns raised

**Rollout Steps**:
```bash
# 1. Record current PROD image
kubectl get deployment ticket-triage-api -n triage-prod -o jsonpath='{.spec.template.spec.containers[0].image}'

# 2. Update PROD deployment
kubectl set image deployment/ticket-triage-api \
  ticket-triage-api=ghcr.io/automation-agent-ai/multilingual-ticket-triage-devops:aws-sha-4216729... \
  -n triage-prod

# 3. Monitor rollout
kubectl rollout status deployment/ticket-triage-api -n triage-prod --timeout=5m

# 4. Verify PROD health
curl https://triage.automation-agent.ai/health

# 5. Test PROD Swagger
# Visit: https://triage.automation-agent.ai/docs
# Submit test ticket via Swagger UI
# Verify inference metadata in response

# 6. Check Grafana metrics
# Visit: https://grafana.automation-agent.ai
# Verify no error spikes, response times normal
```

**Rollback Plan** (if issues):
```bash
# Rollback to previous image
kubectl set image deployment/ticket-triage-api \
  ticket-triage-api=<PREVIOUS_IMAGE> \
  -n triage-prod

kubectl rollout status deployment/ticket-triage-api -n triage-prod
```

---

### 12. Documentation Updates

**API Documentation** — Add to `/docs` endpoint description:
```markdown
## Inference Metadata (New in Phase 10C)

The `/triage` response now includes real-time inference metadata:

- `inference.provider`: LLM provider (`"bedrock"` for AWS)
- `inference.model`: Model/profile used (`"eu.amazon.nova-micro-v1:0"`)
- `inference.region`: AWS region (`"eu-west-1"`)
- `inference.invoked`: True if inference succeeded
- `inference.input_tokens`: Actual tokens consumed (input)
- `inference.output_tokens`: Actual tokens generated (output)
- `inference.latency_ms`: Inference latency in milliseconds
- `inference.invocation_count`: Number of LLM calls (1 or 2 with retry)

Token counts represent the total consumption across all calls for this request,
including retry attempts if validation initially failed.

This metadata proves that Amazon Bedrock Nova Micro genuinely processed
the request and generated the classification dynamically.
```

---

### 13. Evidence for Pre-Defense Demo

**Show Examiners**:
1. Submit ticket in public Swagger UI (https://triage.automation-agent.ai/docs)
2. Scroll to `/triage` response JSON
3. Point out `inference` object with real token counts and latency
4. Submit different ticket, show different token counts
5. Explain: "These numbers come directly from Bedrock Converse API — they prove real inference"

**Key Talking Points**:
- Token usage varies per ticket (not hardcoded)
- Latency reflects actual Bedrock response time
- Model ID confirms Nova Micro in eu-west-1
- Classification results are dynamically generated
- `simulated_success` applies ONLY to downstream actions, NOT LLM

---

### 14. Success Criteria — Achieved ✅

- [x] Bedrock Converse metadata extracted (usage, metrics)
- [x] Metadata propagated through analyzer → agent → API
- [x] New `inference` field added to Pydantic models
- [x] FastAPI response serialization correct
- [x] Backward compatibility preserved (all existing fields)
- [x] Defensive handling of missing fields
- [x] Token aggregation across retries
- [x] 54 automated tests passing
- [x] OpenAPI schema updated (visible in Swagger)
- [x] Commit pushed, CI triggered
- [ ] DEV deployment verified (pending image build)
- [ ] PROD deployment approved and completed (pending DEV validation)

---

## CONCLUSION

Phase 10C implementation is **complete and tested**. The code changes expose real Amazon Bedrock inference metadata in the `/triage` API response, providing trustworthy evidence that Nova Micro genuinely processes each request.

**Next Step**: Deploy to AWS DEV once GitHub Actions build completes, verify real Bedrock metadata, then proceed to PROD with explicit approval.

---

**Report Generated**: October 13, 2026, 01:30 UTC  
**Implementation Status**: ✅ Code Complete · 🔄 Awaiting DEV Deployment  
**Commit**: `4216729` · **Branch**: `feat/aws-bedrock-migration`
