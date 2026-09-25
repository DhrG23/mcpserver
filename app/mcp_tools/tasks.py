from __future__ import annotations

from mcp.server.mcpserver import Context

from app.mcp_tools.registry import mcp_server
from app.permissions.scopes import guarded, resolve_caller
from app.storage.db import get_db, new_id, now, row_to_dict


@mcp_server.tool()
@guarded("create_task")
async def create_task(
    ctx: Context,
    title: str,
    description: str | None = None,
    due_at: float | None = None,
    priority: str = "normal",
    project: str | None = None,
) -> dict:
    """Create a to-do item.

    Args:
        title: Short task title.
        description: Optional longer detail.
        due_at: Optional due time as a Unix timestamp (seconds).
        priority: "low" | "normal" | "high".
        project: Optional grouping label (e.g. "Hackathon").
    """
    caller = resolve_caller(dict(ctx.headers) if ctx.headers else {})
    async with get_db() as db:
        task_id = new_id()
        ts = now()
        await db.execute(
            "INSERT INTO tasks (id, title, description, status, priority, due_at, "
            "project, created_by, created_at, updated_at) "
            "VALUES (?, ?, ?, 'open', ?, ?, ?, ?, ?, ?)",
            (task_id, title, description, priority, due_at, project, caller, ts, ts),
        )
        await db.commit()
    return {"status": "ok", "id": task_id}


@mcp_server.tool()
@guarded("get_tasks")
async def get_tasks(ctx: Context, status: str = "open", project: str | None = None, limit: int = 50) -> dict:
    """List tasks, optionally filtered by status and/or project.

    Args:
        status: "open" | "in_progress" | "done" | "cancelled" | "all".
        project: Optional project label to filter by.
        limit: Max results (default 50).
    """
    clauses, params = [], []
    if status != "all":
        clauses.append("status = ?")
        params.append(status)
    if project:
        clauses.append("project = ?")
        params.append(project)
    where = f"WHERE {' AND '.join(clauses)}" if clauses else ""
    async with get_db() as db:
        cur = await db.execute(
            f"SELECT * FROM tasks {where} ORDER BY due_at IS NULL, due_at ASC, created_at DESC LIMIT ?",
            (*params, limit),
        )
        rows = await cur.fetchall()
    return {"status": "ok", "count": len(rows), "tasks": [row_to_dict(r) for r in rows]}


@mcp_server.tool()
@guarded("complete_task")
async def complete_task(ctx: Context, task_id: str) -> dict:
    """Mark a task as done.

    Args:
        task_id: The id returned by create_task() or get_tasks().
    """
    async with get_db() as db:
        cur = await db.execute(
            "UPDATE tasks SET status = 'done', updated_at = ? WHERE id = ?",
            (now(), task_id),
        )
        await db.commit()
        updated = cur.rowcount > 0
    return {"status": "ok" if updated else "not_found", "id": task_id}
