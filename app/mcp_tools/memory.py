from __future__ import annotations

from mcp.server.mcpserver import Context

from app.mcp_tools.registry import mcp_server
from app.permissions.scopes import guarded, resolve_caller
from app.storage.crypto import encrypt, decrypt
from app.storage.db import get_db, new_id, now, dumps, loads, row_to_dict


@mcp_server.tool()
@guarded("remember")
async def remember(ctx: Context, value: str, key: str | None = None, tags: list[str] | None = None) -> dict:
    """Store a fact, preference, or note in long-term memory for later recall.

    Args:
        value: The information to remember, in plain language.
        key: Optional short label to make this easy to look up/overwrite later
            (e.g. "wifi_password", "daughter_birthday"). Omit for free-form notes.
        tags: Optional categories (e.g. ["family", "finance"]) to aid search.
    """
    caller = resolve_caller(dict(ctx.headers) if ctx.headers else {})
    async with get_db() as db:
        mem_id = new_id()
        ts = now()
        await db.execute(
            "INSERT INTO memory (id, key, value, tags, created_by, created_at, updated_at) "
            "VALUES (?, ?, ?, ?, ?, ?, ?)",
            (mem_id, key, encrypt(value), dumps(tags or []), caller, ts, ts),
        )
        await db.commit()
    return {"status": "ok", "id": mem_id}


@mcp_server.tool()
@guarded("search_memory")
async def search_memory(ctx: Context, query: str, limit: int = 10) -> dict:
    """Search stored memories by keyword match against key, value, and tags.

    Args:
        query: Free-text search term.
        limit: Max results to return (default 10).

    Note on implementation: memory values are encrypted at rest, so this can't
    use a SQL LIKE against ciphertext. It decrypts and filters in Python
    instead -- fine at personal-scale data volumes, would need an encrypted
    search index (or a switch to a searchable-encryption scheme) if this ever
    grew to thousands of entries.
    """
    query_lower = query.lower()
    async with get_db() as db:
        cur = await db.execute("SELECT * FROM memory ORDER BY updated_at DESC")
        rows = await cur.fetchall()

    results = []
    for r in rows:
        d = row_to_dict(r)
        d["value"] = decrypt(d["value"])
        d["tags"] = loads(d["tags"], [])
        haystack = " ".join([d.get("key") or "", d["value"], " ".join(d["tags"])]).lower()
        if query_lower in haystack:
            results.append(d)
        if len(results) >= limit:
            break

    return {"status": "ok", "count": len(results), "results": results}


@mcp_server.tool()
@guarded("forget")
async def forget(ctx: Context, memory_id: str) -> dict:
    """Permanently delete a stored memory by its id.

    Args:
        memory_id: The id returned by remember() or search_memory().
    """
    async with get_db() as db:
        cur = await db.execute("DELETE FROM memory WHERE id = ?", (memory_id,))
        await db.commit()
        deleted = cur.rowcount > 0
    return {"status": "ok" if deleted else "not_found", "id": memory_id}
