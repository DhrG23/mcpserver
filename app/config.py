"""
Central settings. Loads .env (if present) BEFORE anything else reads the
environment, so `python -m app.main` works without `source .env`.
Import this module first in every entrypoint.
"""
from __future__ import annotations

import os
from pathlib import Path

from dotenv import load_dotenv

load_dotenv(Path.cwd() / ".env", override=False)


def _int(name: str, default: int) -> int:
    try:
        return int(os.environ.get(name, default))
    except ValueError:
        return default


def _bool(name: str, default: bool) -> bool:
    v = os.environ.get(name)
    return default if v is None else v.strip().lower() in {"1", "true", "yes", "on"}


class Settings:
    # --- network
    bind_host = os.environ.get("BIND_HOST", "127.0.0.1")
    mcp_port = _int("MCP_PORT", 8000)
    gateway_port = _int("GATEWAY_PORT", 8001)
    forwarded_allow_ips = os.environ.get("FORWARDED_ALLOW_IPS", "127.0.0.1")

    # --- accounts
    allow_registration = _bool("ALLOW_REGISTRATION", False)  # first account is always allowed
    # If set, /auth/register requires this code (for every account, including the first) and
    # ALLOW_REGISTRATION is ignored. Create/show it with:  python3 scripts/invite_code.py
    invite_code = os.environ.get("INVITE_CODE", "").strip()
    token_ttl_days = _int("TOKEN_TTL_DAYS", 30)
    min_password_len = _int("MIN_PASSWORD_LEN", 8)
    login_max_failures = _int("LOGIN_MAX_FAILURES", 5)
    login_window_s = _int("LOGIN_WINDOW_SECONDS", 900)
    ws_connect_per_min_per_ip = _int("WS_CONNECT_PER_MIN_PER_IP", 60)

    # --- devices
    snapshot_stale_after_s = _int("SNAPSHOT_STALE_AFTER_SECONDS", 300)
    allow_private_fetch = _bool("ALLOW_PRIVATE_FETCH", False)

    # --- chat (server.md section 8)
    chat_agent_caller = os.environ.get("CHAT_AGENT_CALLER", "nemotron")
    chat_max_message_chars = _int("CHAT_MAX_MESSAGE_CHARS", 4000)
    chat_rate_limit_per_min = _int("CHAT_RATE_LIMIT_PER_MIN", 20)
    chat_history_retention_days = _int("CHAT_HISTORY_RETENTION_DAYS", 90)
    chat_max_sockets_per_user = _int("CHAT_MAX_SOCKETS_PER_USER", 3)
    # --- chat model backend
    chat_llm_provider = os.environ.get("CHAT_LLM_PROVIDER", "ollama").lower()  # ollama|openai|echo
    chat_llm_base_url = os.environ.get("CHAT_LLM_BASE_URL", "")
    chat_llm_api_key = os.environ.get("CHAT_LLM_API_KEY", "")
    chat_llm_model = os.environ.get("CHAT_LLM_MODEL", "")
    chat_ollama_think = _bool("CHAT_OLLAMA_THINK", False)
    chat_model_timeout_s = _int("CHAT_MODEL_TIMEOUT_SECONDS", 120)
    chat_tool_timeout_s = _int("CHAT_TOOL_TIMEOUT_SECONDS", 30)
    chat_max_tool_rounds = _int("CHAT_MAX_TOOL_ROUNDS", 6)


settings = Settings()
