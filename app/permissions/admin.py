from __future__ import annotations

from fastapi import APIRouter, HTTPException
from pydantic import BaseModel

from app.storage.db import get_db, now, loads, row_to_dict

router = APIRouter(prefix="/approvals", tags=["approvals"])


class DecisionRequest(BaseModel):
    approve: bool


@router.get("")
async def list_approvals(status: str = "pending"):
    """List pending (or all, with status=all) approval requests queued by the permissions layer."""
    async with get_db() as db:
        if status == "all":
            cur = await db.execute("SELECT * FROM pending_approvals ORDER BY created_at DESC")
        else:
            cur = await db.execute(
                "SELECT * FROM pending_approvals WHERE status = ? ORDER BY created_at DESC", (status,)
            )
        rows = await cur.fetchall()
    out = []
    for r in rows:
        d = row_to_dict(r)
        d["args"] = loads(d["args"])
        out.append(d)
    return out


@router.post("/{approval_id}/decide")
async def decide(approval_id: str, body: DecisionRequest):
    """Approve or deny a queued call.

    NOTE (MVP scope): approving here marks the request resolved and unblocks
    a human-facing view of what was asked for. It does not automatically
    replay the original tool call - the caller (Alexa+/Nemotron) should poll
    or be told to retry, and a real deployment would re-invoke the original
    tool with the stored args on approval. Wiring that replay is a documented
    next step (see README).
    """
    new_status = "approved" if body.approve else "denied"
    async with get_db() as db:
        cur = await db.execute(
            "UPDATE pending_approvals SET status = ?, resolved_at = ? WHERE id = ? AND status = 'pending'",
            (new_status, now(), approval_id),
        )
        await db.commit()
        if cur.rowcount == 0:
            raise HTTPException(status_code=404, detail="Approval not found or already resolved")
    return {"status": new_status, "id": approval_id}
