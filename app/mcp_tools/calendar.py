from __future__ import annotations

from mcp.server.mcpserver import Context

from app.mcp_tools.registry import mcp_server
from app.permissions.scopes import guarded, resolve_caller
from app.storage.db import get_db, new_id, now, row_to_dict

DAY_SECONDS = 86400


@mcp_server.tool()
@guarded("get_calendar")
async def get_calendar(ctx: Context, start_at: float, end_at: float) -> dict:
    """List calendar events overlapping a time window.

    Args:
        start_at: Window start as a Unix timestamp (seconds).
        end_at: Window end as a Unix timestamp (seconds).
    """
    async with get_db() as db:
        cur = await db.execute(
            "SELECT * FROM calendar_events WHERE start_at < ? AND end_at > ? ORDER BY start_at ASC",
            (end_at, start_at),
        )
        rows = await cur.fetchall()
    return {"status": "ok", "count": len(rows), "events": [row_to_dict(r) for r in rows]}


@mcp_server.tool()
@guarded("create_event")
async def create_event(
    ctx: Context,
    title: str,
    start_at: float,
    end_at: float,
    location: str | None = None,
    notes: str | None = None,
) -> dict:
    """Create a calendar event.

    Args:
        title: Event title.
        start_at: Start time as a Unix timestamp (seconds).
        end_at: End time as a Unix timestamp (seconds).
        location: Optional location string.
        notes: Optional free-text notes.
    """
    caller = resolve_caller(dict(ctx.headers) if ctx.headers else {})
    async with get_db() as db:
        event_id = new_id()
        await db.execute(
            "INSERT INTO calendar_events (id, title, start_at, end_at, location, notes, "
            "created_by, created_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
            (event_id, title, start_at, end_at, location, notes, caller, now()),
        )
        await db.commit()
    return {"status": "ok", "id": event_id}


@mcp_server.tool()
@guarded("find_free_time")
async def find_free_time(
    ctx: Context, start_at: float, end_at: float, duration_minutes: int = 60
) -> dict:
    """Find free time slots of a given length within a window, based on existing events.

    Args:
        start_at: Window start as a Unix timestamp (seconds).
        end_at: Window end as a Unix timestamp (seconds).
        duration_minutes: Minimum slot length required, in minutes.
    """
    async with get_db() as db:
        cur = await db.execute(
            "SELECT start_at, end_at FROM calendar_events WHERE start_at < ? AND end_at > ? "
            "ORDER BY start_at ASC",
            (end_at, start_at),
        )
        busy = [(r["start_at"], r["end_at"]) for r in await cur.fetchall()]

    duration = duration_minutes * 60
    slots = []
    cursor = start_at
    for b_start, b_end in busy:
        if b_start - cursor >= duration:
            slots.append({"start_at": cursor, "end_at": b_start})
        cursor = max(cursor, b_end)
    if end_at - cursor >= duration:
        slots.append({"start_at": cursor, "end_at": end_at})

    return {"status": "ok", "duration_minutes": duration_minutes, "slots": slots}
