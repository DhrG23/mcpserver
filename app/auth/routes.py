"""
/auth/register, /auth/login, /auth/logout, /auth/me  +  account data erase.

Request fields: `email` OR `username`, `password`, and for register an optional
`name` and `invite_code` (the Node app always sends `invite_code`; it is checked
only when INVITE_CODE is set in .env).
"""
from __future__ import annotations

import asyncio
import hmac
import sqlite3

from fastapi import APIRouter, Depends, HTTPException, Request
from pydantic import BaseModel, ConfigDict

from app.auth.deps import current_user
from app.auth.ratelimit import SlidingWindow
from app.auth.security import DUMMY_HASH, AuthedUser, hash_password, issue_token, revoke_token, verify_password
from app.config import settings
from app.storage.db import get_db, new_id, now

router = APIRouter(tags=["auth"])
_login_failures = SlidingWindow(settings.login_max_failures, settings.login_window_s)
_invite_failures = SlidingWindow(10, 900)      # 10 wrong invite codes per IP per 15 min


class Credentials(BaseModel):
    model_config = ConfigDict(extra="ignore")
    email: str | None = None
    username: str | None = None
    password: str
    name: str | None = None
    invite_code: str | None = None      # register only

    def identity(self) -> str:
        return (self.email or self.username or "").strip().lower()


def client_ip(request: Request) -> str:
    return request.client.host if request.client else "unknown"


@router.post("/auth/register")
async def register(body: Credentials, request: Request):
    ident = body.identity()
    if not ident or len(ident) > 254:
        raise HTTPException(status_code=422, detail="Enter an email address or username.")
    if len(body.password) < settings.min_password_len:
        raise HTTPException(status_code=422, detail=f"Password must be at least {settings.min_password_len} characters.")
    if settings.invite_code:
        # Invite mode: anyone holding the code may register, even after the first account.
        ip = client_ip(request)
        wait = _invite_failures.retry_after(ip)
        if wait:
            raise HTTPException(status_code=429, detail=f"Too many attempts. Try again in {wait // 60 + 1} min.")
        given = (body.invite_code or "").strip().encode()
        if not hmac.compare_digest(given, settings.invite_code.encode()):
            _invite_failures.record(ip)
            raise HTTPException(status_code=403, detail="Invalid invite code.")
    else:
        async with get_db() as db:
            cur = await db.execute("SELECT COUNT(*) AS n FROM users")
            count = (await cur.fetchone())["n"]
        if count > 0 and not settings.allow_registration:
            raise HTTPException(status_code=403, detail="Registration is closed on this server.")
    name = (body.name or ident.split("@")[0]).strip()[:80] or ident
    pw_hash = await asyncio.to_thread(hash_password, body.password)
    user_id = new_id()
    try:
        async with get_db() as db:
            await db.execute(
                "INSERT INTO users (id, identity, display_name, password_hash, created_at) VALUES (?, ?, ?, ?, ?)",
                (user_id, ident, name, pw_hash, now()),
            )
            await db.commit()
    except sqlite3.IntegrityError:
        raise HTTPException(status_code=409, detail="An account with that name already exists.") from None
    return {"token": await issue_token(user_id), "user_name": name}


@router.post("/auth/login")
async def login(body: Credentials, request: Request):
    ident = body.identity()
    key = f"{client_ip(request)}|{ident}"
    wait = _login_failures.retry_after(key)
    if wait:
        raise HTTPException(status_code=429, detail=f"Too many attempts. Try again in {wait // 60 + 1} min.")
    async with get_db() as db:
        cur = await db.execute("SELECT id, display_name, password_hash FROM users WHERE identity = ?", (ident,))
        row = await cur.fetchone()
    ok = await asyncio.to_thread(verify_password, body.password, row["password_hash"] if row else DUMMY_HASH)
    if not row or not ok:
        _login_failures.record(key)
        raise HTTPException(status_code=401, detail="Incorrect name or password.")
    _login_failures.reset(key)
    return {"token": await issue_token(row["id"]), "user_name": row["display_name"]}


@router.post("/auth/logout")
async def logout(user: AuthedUser = Depends(current_user)):
    await revoke_token(user.token_hash)
    from app.chat.hub import hub  # late import: chat depends on auth

    await hub.close_token(user.token_hash, 4401)
    return {"status": "ok"}


@router.get("/auth/me")
async def me(user: AuthedUser = Depends(current_user)):
    return {"user_id": user.id, "user_name": user.name}


@router.delete("/account/data")
async def erase_my_data(user: AuthedUser = Depends(current_user)):
    """'Erase my data': chat history, owned devices and their telemetry/commands. The account and
    sign-in stay. (Path is an assumption; the app does not call it yet.)"""
    from app.chat.hub import hub

    await hub.cancel_all_for_user(user.id)
    async with get_db() as db:
        await db.execute("DELETE FROM chat_messages WHERE user_id = ?", (user.id,))
        await db.execute("DELETE FROM chat_conversations WHERE user_id = ?", (user.id,))
        ids = [r["id"] for r in await (await db.execute("SELECT id FROM devices WHERE user_id = ?", (user.id,))).fetchall()]
        for did in ids:
            await db.execute("DELETE FROM device_telemetry WHERE device_id = ?", (did,))
            await db.execute("DELETE FROM outgoing_commands WHERE device_id = ?", (did,))
        await db.execute("DELETE FROM devices WHERE user_id = ?", (user.id,))
        await db.commit()
    return {"status": "ok", "devices_removed": len(ids)}
