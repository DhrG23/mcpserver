"""
/approvals -- review and decide tool calls that the permission layer queued.

Requires a signed-in user (sees their own chat-originated requests plus requests from
outside callers such as Alexa) or the admin token (sees all). Approving now REPLAYS the
original call with its stored arguments; the result is stored encrypted on the approval
and is never pushed into a chat answer.
"""
from __future__ import annotations

import asyncio

from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel

from app.auth.deps import Principal, user_or_admin
from app.config import settings
from app.permissions.scopes import audit
from app.storage.crypto import decrypt, encrypt
from app.storage.db import get_db, iso, now, dumps, loads, row_to_dict

router = APIRouter(prefix="/approvals", tags=["approvals"])


class DecisionRequest(BaseModel):
    approve: bool


def _visible(row: dict, who: Principal) -> bool:
    return who.is_admin or row["user_id"] is None or (who.user is not None and row["user_id"] == who.user.id)


def _public(row: dict, with_result: bool = False) -> dict:
    out = {k: row[k] for k in ("id", "caller", "tool", "status", "chat_message_id", "chat_call_id")}
    out["args"] = loads(row["args"])
    out["created_at"], out["resolved_at"] = iso(row["created_at"]), iso(row["resolved_at"])
    if with_result and row.get("result"):
        out["result"] = loads(decrypt(row["result"]))
    return out


@router.get("")
async def list_approvals(status: str = "pending", who: Principal = Depends(user_or_admin)):
    async with get_db() as db:
        if status == "all":
            cur = await db.execute("SELECT * FROM pending_approvals ORDER BY created_at DESC LIMIT 200")
        else:
            cur = await db.execute("SELECT * FROM pending_approvals WHERE status = ? ORDER BY created_at DESC LIMIT 200", (status,))
        rows = [row_to_dict(r) for r in await cur.fetchall()]
    return [_public(r) for r in rows if _visible(r, who)]


@router.get("/{approval_id}")
async def get_approval(approval_id: str, who: Principal = Depends(user_or_admin)):
    async with get_db() as db:
        row = await (await db.execute("SELECT * FROM pending_approvals WHERE id = ?", (approval_id,))).fetchone()
    if not row or not _visible(row_to_dict(row), who):
        raise HTTPException(status_code=404, detail="Approval not found.")
    return _public(row_to_dict(row), with_result=True)


@router.post("/{approval_id}/decide")
async def decide(approval_id: str, body: DecisionRequest, who: Principal = Depends(user_or_admin)):
    async with get_db() as db:
        row = await (await db.execute("SELECT * FROM pending_approvals WHERE id = ?", (approval_id,))).fetchone()
        if not row or not _visible(row_to_dict(row), who):
            raise HTTPException(status_code=404, detail="Approval not found or already resolved.")
        new_status = "approved" if body.approve else "denied"
        cur = await db.execute(
            "UPDATE pending_approvals SET status = ?, resolved_at = ? WHERE id = ? AND status = 'pending'",
            (new_status, now(), approval_id),
        )
        await db.commit()
        if cur.rowcount == 0:
            raise HTTPException(status_code=404, detail="Approval not found or already resolved.")
    approval = row_to_dict(row)
    await audit(approval["caller"], approval["tool"], new_status, loads(approval["args"]), approval["user_id"])

    ok = False
    if body.approve:
        from app.mcp_tools.catalog import replay_unguarded

        try:
            result = await asyncio.wait_for(
                replay_unguarded(approval["caller"], approval["tool"], loads(approval["args"], {})),
                timeout=settings.chat_tool_timeout_s,
            )
            ok = result.get("status") not in ("error", "denied") if isinstance(result, dict) else True
        except Exception as e:  # noqa: BLE001 - recorded, never raised to the approver
            result = {"status": "error", "message": type(e).__name__}
        async with get_db() as db:
            await db.execute("UPDATE pending_approvals SET result = ? WHERE id = ?", (encrypt(dumps(result)), approval_id))
            await db.commit()

    from app.chat.hub import hub

    await hub.on_approval_decided(approval, approved=body.approve, ok=ok)
    return {"status": new_status, "id": approval_id, "replayed": body.approve, "ok": ok if body.approve else None}
