"""FastAPI dependencies for authenticated routes."""
from __future__ import annotations

import hmac
import os

from fastapi import Header, HTTPException

from app.auth.security import AuthedUser, bearer_from_header, user_for_token


async def current_user(authorization: str | None = Header(default=None)) -> AuthedUser:
    token = bearer_from_header(authorization)
    user = await user_for_token(token) if token else None
    if user is None:
        raise HTTPException(status_code=401, detail="Your session is no longer valid. Please sign in again.")
    return user


class Principal:
    """Either a signed-in user, or the server admin (ADMIN_TOKEN)."""

    def __init__(self, user: AuthedUser | None, is_admin: bool) -> None:
        self.user, self.is_admin = user, is_admin


async def user_or_admin(authorization: str | None = Header(default=None)) -> Principal:
    token = bearer_from_header(authorization)
    if token:
        admin = os.environ.get("ADMIN_TOKEN", "dev-admin-token")
        if hmac.compare_digest(token.encode(), admin.encode()):
            return Principal(None, True)
        user = await user_for_token(token)
        if user:
            return Principal(user, False)
    raise HTTPException(status_code=401, detail="Your session is no longer valid. Please sign in again.")
