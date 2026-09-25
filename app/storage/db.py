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

DB_PATH = os.environ.get("PERSONAL_AI_DB_PATH", "/data/personal_ai.db")

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
"""


def new_id() -> str:
    return uuid.uuid4().hex[:12]


def now() -> float:
    return time.time()


_initialized = False


@asynccontextmanager
async def get_db() -> AsyncIterator[aiosqlite.Connection]:
    global _initialized
    os.makedirs(os.path.dirname(DB_PATH), exist_ok=True)
    db = await aiosqlite.connect(DB_PATH)
    db.row_factory = aiosqlite.Row
    try:
        if not _initialized:
            await db.executescript(SCHEMA)
            await db.commit()
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
