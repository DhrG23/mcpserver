"""
Permission model.

Every MCP tool call arrives with an HTTP Authorization header. We resolve that
to a *caller identity* (e.g. "alexa", "nemotron", a specific human owner),
then check a scope table before letting the tool run.

Scopes:
  allow    - runs immediately
  approval - runs only after a human approves it (see pending_approvals table)
  deny     - rejected outright

Defaults are deliberately conservative: anything not explicitly listed for a
caller is denied. This file is the single place you edit to change what
Alexa+ vs. the Nemotron agent are allowed to do.
"""
from __future__ import annotations

import functools
import os

from app.storage.db import get_db, new_id, now, dumps

# --- Caller identity -------------------------------------------------------

# Maps a bearer token (set via env vars / your deployment secrets) to a
# caller id used everywhere else in this app. Rotate these per environment.
_CALLER_TOKENS: dict[str, str] = {
    os.environ.get("ALEXA_TOKEN", "dev-alexa-token"): "alexa",
    os.environ.get("NEMOTRON_TOKEN", "dev-nemotron-token"): "nemotron",
    os.environ.get("OLLAMA_TOKEN", "dev-ollama-token"): "ollama",
    os.environ.get("ADMIN_TOKEN", "dev-admin-token"): "admin",
}


class PermissionError_(Exception):
    """Raised when a caller isn't allowed to run a tool."""


class ApprovalRequired(Exception):
    """Raised when a call was queued for human approval instead of run."""

    def __init__(self, approval_id: str):
        self.approval_id = approval_id
        super().__init__(f"Approval required, queued as {approval_id}")


def resolve_caller(headers: dict[str, str]) -> str:
    """Turn an incoming Authorization header into a caller id. Unknown/missing -> 'anonymous'."""
    auth = headers.get("authorization") or headers.get("Authorization") or ""
    token = auth.removeprefix("Bearer ").strip()
    return _CALLER_TOKENS.get(token, "anonymous")


# --- Default scope table ----------------------------------------------------
# (caller, tool) -> scope. Seeded on first run; editable later via the
# `permissions` table directly or a future admin tool.

DEFAULT_SCOPES: dict[tuple[str, str], str] = {
    # Alexa+: fast, voice-first, read-heavy. Writes are small and reversible.
    ("alexa", "search_memory"): "allow",
    ("alexa", "remember"): "allow",
    ("alexa", "get_tasks"): "allow",
    ("alexa", "create_task"): "allow",
    ("alexa", "complete_task"): "allow",
    ("alexa", "get_calendar"): "allow",
    ("alexa", "create_event"): "approval",
    ("alexa", "find_free_time"): "allow",
    ("alexa", "search_web"): "allow",
    ("alexa", "fetch_webpage"): "allow",
    ("alexa", "search_files"): "allow",
    ("alexa", "read_file"): "allow",
    ("alexa", "list_devices"): "allow",
    ("alexa", "get_device_context"): "allow",
    ("alexa", "send_notification"): "approval",
    ("alexa", "create_automation"): "deny",
    ("alexa", "forget"): "approval",

    # Nemotron: autonomous, chains many tools. Give it more reach, but keep
    # anything destructive or device-controlling behind approval.
    ("nemotron", "search_memory"): "allow",
    ("nemotron", "remember"): "allow",
    ("nemotron", "forget"): "approval",
    ("nemotron", "get_tasks"): "allow",
    ("nemotron", "create_task"): "allow",
    ("nemotron", "complete_task"): "allow",
    ("nemotron", "get_calendar"): "allow",
    ("nemotron", "create_event"): "allow",
    ("nemotron", "find_free_time"): "allow",
    ("nemotron", "search_web"): "allow",
    ("nemotron", "fetch_webpage"): "allow",
    ("nemotron", "search_files"): "allow",
    ("nemotron", "read_file"): "allow",
    ("nemotron", "list_devices"): "allow",
    ("nemotron", "get_device_context"): "allow",
    ("nemotron", "send_notification"): "approval",
    ("nemotron", "create_automation"): "approval",

    # Ollama: your own fully-local agent on your own LAN. Trusted more than a
    # cloud-hosted caller by nature of the deployment, but still kept off
    # anything device-affecting or destructive by default -- tighten or loosen
    # this table once you see how you actually want to use it day to day.
    ("ollama", "search_memory"): "allow",
    ("ollama", "remember"): "allow",
    ("ollama", "forget"): "approval",
    ("ollama", "get_tasks"): "allow",
    ("ollama", "create_task"): "allow",
    ("ollama", "complete_task"): "allow",
    ("ollama", "get_calendar"): "allow",
    ("ollama", "create_event"): "allow",
    ("ollama", "find_free_time"): "allow",
    ("ollama", "search_web"): "allow",
    ("ollama", "fetch_webpage"): "allow",
    ("ollama", "search_files"): "allow",
    ("ollama", "read_file"): "allow",
    ("ollama", "list_devices"): "allow",
    ("ollama", "get_device_context"): "allow",
    ("ollama", "send_notification"): "approval",
    ("ollama", "create_automation"): "approval",

    # Admin (you, during development / debugging): everything allowed.
}

_ADMIN_WILDCARD = "admin"


async def seed_permissions() -> None:
    async with get_db() as db:
        for (caller, tool), scope in DEFAULT_SCOPES.items():
            await db.execute(
                "INSERT OR IGNORE INTO permissions (caller, tool, scope) VALUES (?, ?, ?)",
                (caller, tool, scope),
            )
        await db.commit()


async def check(caller: str, tool: str, args: dict) -> None:
    """
    Raises PermissionError_ if denied, ApprovalRequired if queued, or
    returns normally if allowed. Call this at the top of every tool.
    """
    if caller == _ADMIN_WILDCARD:
        return

    async with get_db() as db:
        cur = await db.execute(
            "SELECT scope FROM permissions WHERE caller = ? AND tool = ?",
            (caller, tool),
        )
        row = await cur.fetchone()

    scope = row["scope"] if row else "deny"  # default-deny for unlisted tools

    if scope == "allow":
        return
    if scope == "deny":
        raise PermissionError_(f"'{caller}' is not permitted to call '{tool}'")
    if scope == "approval":
        async with get_db() as db:
            approval_id = new_id()
            await db.execute(
                "INSERT INTO pending_approvals (id, caller, tool, args, status, created_at) "
                "VALUES (?, ?, ?, ?, 'pending', ?)",
                (approval_id, caller, tool, dumps(args), now()),
            )
            await db.commit()
        raise ApprovalRequired(approval_id)

    raise PermissionError_(f"Unknown scope '{scope}' for ({caller}, {tool})")


def guarded(tool_name: str):
    """
    Decorator for MCP tool functions. Expects the wrapped function's first
    positional/keyword arg to be `ctx` (the FastMCP Context, which carries
    request headers). Resolves the caller, checks the scope table, and
    returns a clean structured result instead of raising a raw exception,
    so the calling AI (Alexa+ or Nemotron) gets something it can act on
    ("this needs approval") rather than an opaque protocol error.
    """

    def decorator(fn):
        @functools.wraps(fn)
        async def wrapper(ctx, *args, **kwargs):
            headers = dict(ctx.headers) if getattr(ctx, "headers", None) else {}
            caller = resolve_caller(headers)
            call_args = {"args": args, "kwargs": kwargs}
            try:
                await check(caller, tool_name, call_args)
            except ApprovalRequired as e:
                return {
                    "status": "approval_required",
                    "approval_id": e.approval_id,
                    "message": (
                        f"'{tool_name}' needs your approval before it runs. "
                        f"Approve or deny via the /approvals endpoint."
                    ),
                }
            except PermissionError_ as e:
                return {"status": "denied", "message": str(e)}
            return await fn(ctx, *args, **kwargs)

        return wrapper

    return decorator
