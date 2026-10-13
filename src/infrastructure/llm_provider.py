"""
Select the LLM client from configuration.

llm.provider:
  ollama   — local default. Uses OllamaClient and llm.base_url.
  bedrock  — explicit AWS configuration. Uses BedrockClient and the
             instance role. Never selected unless provider is bedrock.
"""

from __future__ import annotations


def create_llm_client(config: dict):
    """
    Build an object with generate_json(prompt: str) -> str.

    Unknown providers raise ValueError. A missing provider stays on Ollama
    so existing config and tests keep the local client.
    """
    provider = str(config.get("provider", "ollama")).strip().lower()

    if provider == "ollama":
        from src.infrastructure.llm_client import OllamaClient

        base_url = config.get("base_url")
        if not base_url:
            raise ValueError("llm.base_url is required when provider is ollama")
        return OllamaClient(
            base_url=base_url,
            model_name=config["model_name"],
            temperature=config.get("temperature", 0.1),
            timeout_seconds=config.get("timeout_seconds", 120),
        )

    if provider == "bedrock":
        from src.infrastructure.bedrock_client import BedrockClient

        model_id = config.get("inference_profile") or config.get("model_name")
        if not model_id:
            raise ValueError("llm.model_name is required when provider is bedrock")
        return BedrockClient(
            model_id=model_id,
            region=config.get("region", "eu-west-1"),
            temperature=config.get("temperature", 0.1),
            timeout_seconds=config.get("timeout_seconds", 120),
            max_tokens=config.get("max_tokens", 1024),
            connect_timeout_seconds=config.get("connect_timeout_seconds", 10),
            top_p=config.get("top_p"),
        )

    raise ValueError(
        f"Unsupported LLM provider: '{provider}'. Supported providers: ollama, bedrock"
    )


def create_reviewer_client(llm_cfg: dict, reviewer_cfg: dict):
    """
    Build the reviewer client.

    reviewer.provider overrides the primary provider. When it is omitted, the
    reviewer uses the same provider as the primary client. Ollama remains the
    default when neither section sets a provider.
    """
    provider = str(
        reviewer_cfg.get("provider", llm_cfg.get("provider", "ollama"))
    ).strip().lower()
    client_cfg: dict = {
        "provider": provider,
        "model_name": reviewer_cfg["model_name"],
        "temperature": reviewer_cfg.get("temperature", 0.1),
        "timeout_seconds": reviewer_cfg.get(
            "timeout_seconds", llm_cfg.get("timeout_seconds", 120)
        ),
    }
    if provider == "ollama":
        base_url = reviewer_cfg.get("base_url", llm_cfg.get("base_url"))
        if not base_url:
            raise ValueError("llm.base_url is required when the reviewer provider is ollama")
        client_cfg["base_url"] = base_url
    else:
        client_cfg["region"] = reviewer_cfg.get("region", llm_cfg.get("region", "eu-west-1"))
        client_cfg["max_tokens"] = reviewer_cfg.get(
            "max_tokens", llm_cfg.get("max_tokens", 1024)
        )
        client_cfg["connect_timeout_seconds"] = reviewer_cfg.get(
            "connect_timeout_seconds", llm_cfg.get("connect_timeout_seconds", 10)
        )
        if "top_p" in reviewer_cfg:
            client_cfg["top_p"] = reviewer_cfg["top_p"]
        elif "top_p" in llm_cfg:
            client_cfg["top_p"] = llm_cfg["top_p"]
        profile = reviewer_cfg.get("inference_profile", llm_cfg.get("inference_profile"))
        if profile:
            client_cfg["inference_profile"] = profile
    return create_llm_client(client_cfg)
