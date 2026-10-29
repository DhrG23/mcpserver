"""Password hashing (scrypt, stdlib) and session-token helpers."""
from __future__ import annotations

import base64
import hashlib
import hmac
import os
import secrets
import time
from dataclasses import dataclass

from app.config import settings
from app.storage.crypto import hash_token
from app.storage.db import get_db, new_id, now

_N, _R, _P = 2**14, 8, 1


def hash_password(password: str) -> str:
    salt = os.urandom(16)
    dk = hashlib.scrypt(password.encode(), salt=salt, n=_N, r=_R, p=_P, dklen=32)
    return "scrypt${}${}${}${}${}".format(_N, _R, _P, base64.b64encode(salt).decode(), base64.b64encode(dk).decode())


def verify_password(password: str, stored: str) -> bool:
    try:
        _, n, r, p, salt_b64, dk_b64 = stored.split("$")
        salt, expected = base64.b64decode(salt_b64), base64.b64decode(dk_b64)
        dk = hashlib.scrypt(password.encode(), salt=salt, n=int(n), r=int(r), p=int(p), dklen=len(expected))
    except Exception:  # noqa: BLE001 - malformed hash == failed login
        return False
    return hmac.compare_digest(dk, expected)


# Verified against when the account doesn't exist, so timing doesn't reveal which accounts exist.
DUMMY_HASH = hash_password("not-a-real-password")


@dataclass
class AuthedUser:
    id: str
    name: str
    token_hash: str


async def issue_token(user_id: str) -> str:
    token = secrets.token_urlsafe(32)
    ts = now()
    async with get_db() as db:
        await db.execute(
            "INSERT INTO user_tokens (token_hash, user_id, created_at, expires_at) VALUES (?, ?, ?, ?)",
            (hash_token(token), user_id, ts, ts + settings.token_ttl_days * 86400),
        )
        await db.commit()
    return token


def bearer_from_header(value: str | None) -> str | None:
    if not value or not value.lower().startswith("bearer "):
        return None
    token = value[7:].strip()
    return token or None


async def user_for_token(token: str) -> AuthedUser | None:
    """Valid, unexpired, unrevoked token -> user. Hash comparison is constant-time."""
    h = hash_token(token)
    async with get_db() as db:
        cur = await db.execute(
            "SELECT t.token_hash, t.expires_at, t.revoked_at, u.id, u.display_name "
            "FROM user_tokens t JOIN users u ON u.id = t.user_id WHERE t.token_hash = ?",
            (h,),
        )
        row = await cur.fetchone()
    if not row or not hmac.compare_digest(row["token_hash"], h):
        return None
    if row["revoked_at"] is not None or row["expires_at"] < time.time():
        return None
    return AuthedUser(id=row["id"], name=row["display_name"], token_hash=h)


async def revoke_token(token_hash: str) -> None:
    async with get_db() as db:
        await db.execute("UPDATE user_tokens SET revoked_at = ? WHERE token_hash = ? AND revoked_at IS NULL", (now(), token_hash))
        await db.commit()
