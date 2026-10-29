"""Invite-code registration (INVITE_CODE in .env)."""
from app.auth import routes
from app.config import settings

CODE = "NODE-TEST-CODE1"
BODY = {"email": "invited@example.com", "password": "longenough1"}


def test_register_needs_the_invite_code(client, monkeypatch):
    monkeypatch.setattr(settings, "invite_code", CODE)
    routes._invite_failures._hits.clear()

    r = client.post("/auth/register", json=BODY)                         # no code
    assert r.status_code == 403 and r.json()["detail"] == "Invalid invite code."
    r = client.post("/auth/register", json={**BODY, "invite_code": "wrong"})
    assert r.status_code == 403

    r = client.post("/auth/register", json={**BODY, "invite_code": f"  {CODE} "})   # spaces are ignored
    assert r.status_code == 200 and r.json()["token"]
    routes._invite_failures._hits.clear()


def test_invite_code_works_after_the_first_account(client, monkeypatch):
    """With a code set, registration stays open to code holders even though accounts exist."""
    monkeypatch.setattr(settings, "invite_code", CODE)
    monkeypatch.setattr(settings, "allow_registration", False)
    routes._invite_failures._hits.clear()
    r = client.post("/auth/register", json={"email": "second@example.com", "password": "longenough1", "invite_code": CODE})
    assert r.status_code == 200
    routes._invite_failures._hits.clear()


def test_guessing_the_code_is_throttled(client, monkeypatch):
    monkeypatch.setattr(settings, "invite_code", CODE)
    routes._invite_failures._hits.clear()
    for i in range(10):
        r = client.post("/auth/register", json={"email": f"g{i}@example.com", "password": "longenough1", "invite_code": "nope"})
        assert r.status_code == 403
    r = client.post("/auth/register", json={"email": "late@example.com", "password": "longenough1", "invite_code": CODE})
    assert r.status_code == 429                                          # even the right code is refused for a while
    routes._invite_failures._hits.clear()
