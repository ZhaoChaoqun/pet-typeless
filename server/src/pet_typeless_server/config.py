"""Configuration management via environment variables.

All credentials and server settings are loaded from
environment variables (or a .env file via python-dotenv).
"""

from __future__ import annotations

import os
from dataclasses import dataclass

from dotenv import load_dotenv


def _require_env(key: str) -> str:
    """Get a required environment variable or raise."""
    value = os.environ.get(key, "").strip()
    if not value:
        raise EnvironmentError(f"Required environment variable {key!r} is not set")
    return value


def _optional_env(key: str, default: str = "") -> str:
    """Get an optional environment variable with a default."""
    return os.environ.get(key, default).strip() or default


@dataclass(frozen=True)
class Settings:
    """Immutable application settings loaded from environment."""

    # Azure Speech
    azure_speech_key: str
    azure_speech_region: str

    # Azure OpenAI
    azure_openai_api_key: str
    azure_openai_endpoint: str
    azure_openai_deployment: str
    azure_openai_api_version: str

    # 豆包 ASR (bigmodel_async)
    doubao_app_key: str
    doubao_access_key: str
    doubao_resource_id: str

    # Server
    api_token: str
    host: str
    port: int

    # Rewrite
    rewrite_timeout: float


def load_settings() -> Settings:
    """Load settings from environment variables.

    Call this once at startup.  A .env file in the current working
    directory (or parent) is loaded automatically via python-dotenv.
    """
    load_dotenv()

    return Settings(
        # Azure Speech
        azure_speech_key=_require_env("AZURE_SPEECH_KEY"),
        azure_speech_region=_require_env("AZURE_SPEECH_REGION"),
        # Azure OpenAI
        azure_openai_api_key=_require_env("AZURE_OPENAI_API_KEY"),
        azure_openai_endpoint=_require_env("AZURE_OPENAI_ENDPOINT"),
        azure_openai_deployment=_optional_env("AZURE_OPENAI_DEPLOYMENT", "gpt-5.4-mini"),
        azure_openai_api_version=_optional_env("AZURE_OPENAI_API_VERSION", "2024-10-21"),
        # 豆包 ASR
        doubao_app_key=_optional_env("DOUBAO_APP_KEY"),
        doubao_access_key=_optional_env("DOUBAO_ACCESS_KEY"),
        doubao_resource_id=_optional_env("DOUBAO_RESOURCE_ID", "volc.bigasr.sauc.duration"),
        # Server
        api_token=_require_env("API_TOKEN"),
        host=_optional_env("HOST", "0.0.0.0"),
        port=int(_optional_env("PORT", "8000")),
        # Rewrite
        rewrite_timeout=float(_optional_env("REWRITE_TIMEOUT", "5.0")),
    )
