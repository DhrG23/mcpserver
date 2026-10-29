"""Test environment: temp database, echo model, known tokens. Must run before `app` is imported."""
import os
import tempfile

from cryptography.fernet import Fernet

_tmp = tempfile.mkdtemp()
os.environ.update(
    PERSONAL_AI_DB_PATH=f"{_tmp}/test.db", FILES_ROOT=f"{_tmp}/files",
    DATA_ENCRYPTION_KEY=Fernet.generate_key().decode(),
    NEMOTRON_TOKEN="t-nemotron", OLLAMA_TOKEN="t-ollama", ALEXA_TOKEN="t-alexa", ADMIN_TOKEN="t-admin",
    CHAT_LLM_PROVIDER="echo", CHAT_AGENT_CALLER="nemotron", ALLOW_REGISTRATION="true",
    INVITE_CODE="",          # a real .env may set one; tests register without it (test_invite.py sets its own)
    CHAT_RATE_LIMIT_PER_MIN="1000", WS_CONNECT_PER_MIN_PER_IP="1000",
)

import pytest  # noqa: E402
from starlette.testclient import TestClient  # noqa: E402


@pytest.fixture(scope="session")
def client():
    from app.main import gateway_app

    with TestClient(gateway_app) as c:   # `with` runs the lifespan (seeds permissions)
        yield c


def _register(client, ident: str) -> str:
    r = client.post("/auth/register", json={"email": ident, "password": "correct horse battery", "name": ident.split("@")[0]})
    assert r.status_code == 200, r.text
    return r.json()["token"]


@pytest.fixture(scope="session")
def token(client):
    return _register(client, "owner@example.com")


@pytest.fixture(scope="session")
def other_token(client):
    return _register(client, "guest@example.com")
