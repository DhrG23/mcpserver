from __future__ import annotations

from mcp.server.mcpserver import Context

from app.mcp_tools.registry import mcp_server
from app.permissions.scopes import guarded, resolve_caller
from app.storage.db import get_db, new_id, now, dumps, row_to_dict, loads


@mcp_server.tool()
@guarded("create_automation")
async def create_automation(ctx: Context, name: str, trigger: dict, action: dict) -> dict:
    """Create an automation rule: when `trigger` fires, run `action`.

    NOTE (MVP scope): this stores the rule. A scheduler process that watches
    triggers and actually invokes the action tool is a follow-up piece, not
    yet wired in this server — see README "Next steps".

    Args:
        trigger: e.g. {"type": "schedule", "cron": "0 9 * * SUN"} or
                 {"type": "event", "source": "device", "kind": "package_delivered"}.
        action: e.g. {"tool": "send_notification", "args": {"device_id": "...", "title": "...", "body": "..."}}.
    """
    caller = resolve_caller(dict(ctx.headers) if ctx.headers else {})
    async with get_db() as db:
        automation_id = new_id()
        await db.execute(
            "INSERT INTO automations (id, name, trigger, action, enabled, created_by, created_at) "
            "VALUES (?, ?, ?, ?, 1, ?, ?)",
            (automation_id, name, dumps(trigger), dumps(action), caller, now()),
        )
        await db.commit()
    return {"status": "ok", "id": automation_id}


@mcp_server.tool()
@guarded("get_tasks")  # automations are read-adjacent to tasks; reuse that scope rather than adding a new one
async def get_automations(ctx: Context) -> dict:
    """List all stored automation rules."""
    async with get_db() as db:
        cur = await db.execute("SELECT * FROM automations ORDER BY created_at DESC")
        rows = await cur.fetchall()
    out = []
    for r in rows:
        d = row_to_dict(r)
        d["trigger"] = loads(d["trigger"])
        d["action"] = loads(d["action"])
        out.append(d)
    return {"status": "ok", "count": len(out), "automations": out}
