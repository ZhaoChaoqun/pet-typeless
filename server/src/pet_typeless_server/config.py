"""Configuration management via environment variables.

豆包 ASR 凭证和服务器设置从环境变量（或 .env 文件）加载。
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

    # 豆包 ASR
    doubao_app_key: str
    doubao_access_key: str
    doubao_resource_id: str

    # Server
    api_token: str
    host: str
    port: int


def load_settings() -> Settings:
    """Load settings from environment variables.

    Call this once at startup.  A .env file in the current working
    directory (or parent) is loaded automatically via python-dotenv.
    """
    load_dotenv()

    return Settings(
        # 豆包 ASR
        doubao_app_key=_require_env("DOUBAO_APP_KEY"),
        doubao_access_key=_require_env("DOUBAO_ACCESS_KEY"),
        doubao_resource_id=_optional_env(
            "DOUBAO_RESOURCE_ID", "volc.bigasr.sauc.duration"
        ),
        # Server
        api_token=_require_env("API_TOKEN"),
        host=_optional_env("HOST", "0.0.0.0"),
        port=int(_optional_env("PORT", "8000")),
    )
