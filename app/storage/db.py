"""
Shared SQLite storage layer.

Single-file SQLite is intentional for a personal-scale, single-VPS deployment.
Swap get_db() for a Postgres pool later without touching callers if this grows.
"""
from __future__ import annotations

import json
import os
import time
import uuid
from contextlib import asynccontextmanager
from typing import Any, AsyncIterator

import aiosqlite

import app.config  # noqa: F401  (loads .env first)

DB_PATH = os.environ.get("PERSONAL_AI_DB_PATH", "./data/personal_ai.db")

SCHEMA = """
CREATE TABLE IF NOT EXISTS memory (
    id          TEXT PRIMARY KEY,
    key         TEXT,
    value       TEXT NOT NULL,     -- ENCRYPTED (see app/storage/crypto.py)
    tags        TEXT,             -- JSON array
    created_by  TEXT,             -- caller id that stored it
    created_at  REAL NOT NULL,
    updated_at  REAL NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_memory_key ON memory(key);

CREATE TABLE IF NOT EXISTS tasks (
    id          TEXT PRIMARY KEY,
    title       TEXT NOT NULL,
    description TEXT,
    status      TEXT NOT NULL DEFAULT 'open',   -- open|in_progress|done|cancelled
    priority    TEXT DEFAULT 'normal',           -- low|normal|high
    due_at      REAL,
    project     TEXT,
    created_by  TEXT,
    created_at  REAL NOT NULL,
    updated_at  REAL NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_tasks_status ON tasks(status);

CREATE TABLE IF NOT EXISTS calendar_events (
    id          TEXT PRIMARY KEY,
    title       TEXT NOT NULL,
    start_at    REAL NOT NULL,
    end_at      REAL NOT NULL,
    location    TEXT,
    notes       TEXT,
    created_by  TEXT,
    created_at  REAL NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_events_start ON calendar_events(start_at);

CREATE TABLE IF NOT EXISTS devices (
    id          TEXT PRIMARY KEY,
    name        TEXT NOT NULL,
    platform    TEXT NOT NULL,     -- linux|android|ios|ipados|macos
    owner       TEXT NOT NULL,     -- which human owns this node
    token_hash  TEXT NOT NULL UNIQUE,  -- SHA-256 of the bearer token; plaintext never stored
    status      TEXT NOT NULL DEFAULT 'offline',  -- online|offline
    last_seen   REAL,
    last_battery      REAL,       -- not sensitive enough to encrypt; see README
    created_at  REAL NOT NULL
);

CREATE TABLE IF NOT EXISTS device_telemetry (
    id          TEXT PRIMARY KEY,
    device_id   TEXT NOT NULL,
    kind        TEXT NOT NULL,     -- battery|location|screenshot|notification|sensor|status
    payload     TEXT NOT NULL,     -- ENCRYPTED JSON (see app/storage/crypto.py)
    created_at  REAL NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_telemetry_device ON device_telemetry(device_id, created_at DESC);

CREATE TABLE IF NOT EXISTS permissions (
    caller      TEXT NOT NULL,     -- e.g. alexa, nemotron
    tool        TEXT NOT NULL,     -- e.g. create_task, get_device_context
    scope       TEXT NOT NULL,     -- allow|deny|approval
    PRIMARY KEY (caller, tool)
);

CREATE TABLE IF NOT EXISTS outgoing_commands (
    id          TEXT PRIMARY KEY,
    device_id   TEXT NOT NULL,
    kind        TEXT NOT NULL,     -- notification|request_screenshot|run_automation
    payload     TEXT NOT NULL,     -- JSON
    status      TEXT NOT NULL DEFAULT 'pending',  -- pending|delivered
    created_at  REAL NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_commands_device ON outgoing_commands(device_id, status);

CREATE TABLE IF NOT EXISTS automations (
    id          TEXT PRIMARY KEY,
    name        TEXT NOT NULL,
    trigger     TEXT NOT NULL,     -- JSON: {"type": "schedule"|"event", ...}
    action      TEXT NOT NULL,     -- JSON: {"tool": "...", "args": {...}}
    enabled     INTEGER NOT NULL DEFAULT 1,
    created_by  TEXT,
    created_at  REAL NOT NULL
);

CREATE TABLE IF NOT EXISTS pending_approvals (
    id          TEXT PRIMARY KEY,
    caller      TEXT NOT NULL,
    tool        TEXT NOT NULL,
    args        TEXT NOT NULL,     -- JSON
    status      TEXT NOT NULL DEFAULT 'pending',  -- pending|approved|denied|expired
    created_at  REAL NOT NULL,
    resolved_at REAL
);
CREATE TABLE IF NOT EXISTS users (
    id            TEXT PRIMARY KEY,
    identity      TEXT NOT NULL UNIQUE COLLATE NOCASE,  -- email or username used to sign in
    display_name  TEXT NOT NULL,
    password_hash TEXT NOT NULL,                        -- scrypt, see app/auth/security.py
    created_at    REAL NOT NULL
);

CREATE TABLE IF NOT EXISTS user_tokens (
    token_hash  TEXT PRIMARY KEY,   -- SHA-256 of the bearer token; plaintext never stored
    user_id     TEXT NOT NULL,
    created_at  REAL NOT NULL,
    expires_at  REAL NOT NULL,
    revoked_at  REAL
);
CREATE INDEX IF NOT EXISTS idx_user_tokens_user ON user_tokens(user_id);

CREATE TABLE IF NOT EXISTS chat_conversations (
    id          TEXT PRIMARY KEY,
    user_id     TEXT NOT NULL,
    created_at  REAL NOT NULL,
    updated_at  REAL NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_conv_user ON chat_conversations(user_id);

CREATE TABLE IF NOT EXISTS chat_messages (
    id              TEXT PRIMARY KEY,   -- user rows: the app's client_id
    conversation_id TEXT NOT NULL,
    user_id         TEXT NOT NULL,
    role            TEXT NOT NULL,      -- user|assistant|system
    text            TEXT NOT NULL,      -- ENCRYPTED
    status          TEXT,               -- assistant: complete|streaming|cancelled|interrupted|error
    last_seq        INTEGER NOT NULL DEFAULT 0,
    tools_json      TEXT,               -- ENCRYPTED JSON list
    reply_to        TEXT,
    created_at      REAL NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_chat_conv_created ON chat_messages(conversation_id, created_at);

CREATE TABLE IF NOT EXISTS audit_log (
    id          TEXT PRIMARY KEY,
    ts          REAL NOT NULL,
    caller      TEXT NOT NULL,
    tool        TEXT NOT NULL,
    decision    TEXT NOT NULL,      -- allow|approval|deny|approved|denied
    user_id     TEXT,
    detail      TEXT                -- ids/arg NAMES only, never values
);
CREATE INDEX IF NOT EXISTS idx_audit_ts ON audit_log(ts);
"""


# Columns added after the first release. Applied idempotently on startup.
MIGRATIONS: list[tuple[str, str, str]] = [
    ("devices", "user_id", "TEXT"),
    ("devices", "external_id", "TEXT"),   # the app's own device identifier
    ("pending_approvals", "user_id", "TEXT"),
    ("pending_approvals", "chat_message_id", "TEXT"),
    ("pending_approvals", "chat_call_id", "TEXT"),
    ("pending_approvals", "result", "TEXT"),   # ENCRYPTED JSON of the replayed call
]


async def _migrate(db: aiosqlite.Connection) -> None:
    for table, column, decl in MIGRATIONS:
        cur = await db.execute(f"PRAGMA table_info({table})")
        cols = {r["name"] for r in await cur.fetchall()}
        if column not in cols:
            await db.execute(f"ALTER TABLE {table} ADD COLUMN {column} {decl}")
    await db.execute("CREATE INDEX IF NOT EXISTS idx_devices_user ON devices(user_id, external_id)")
    await db.commit()


def new_id() -> str:
    return uuid.uuid4().hex[:12]


def iso(ts: float | None) -> str | None:
    """Epoch seconds -> ISO-8601 UTC ('...Z'), as the Node app expects."""
    if ts is None:
        return None
    from datetime import datetime, timezone

    return datetime.fromtimestamp(ts, tz=timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def now() -> float:
    return time.time()


_initialized = False


@asynccontextmanager
async def get_db() -> AsyncIterator[aiosqlite.Connection]:
    global _initialized
    os.makedirs(os.path.dirname(os.path.abspath(DB_PATH)), exist_ok=True)
    db = await aiosqlite.connect(DB_PATH)
    db.row_factory = aiosqlite.Row
    try:
        if not _initialized:
            await db.execute("PRAGMA journal_mode=WAL")
            await db.executescript(SCHEMA)
            await db.commit()
            await _migrate(db)
            _initialized = True
        yield db
    finally:
        await db.close()


def row_to_dict(row: aiosqlite.Row) -> dict[str, Any]:
    return {k: row[k] for k in row.keys()}


def dumps(obj: Any) -> str:
    return json.dumps(obj, default=str)


def loads(text: str | None, default: Any = None) -> Any:
    if not text:
        return default
    return json.loads(text)
