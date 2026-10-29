"""Chat persistence. Message text and tool info are Fernet-encrypted; nothing here logs content."""
from __future__ import annotations

import time
from typing import Any

from app.storage.crypto import decrypt, encrypt
from app.storage.db import dumps, get_db, iso, loads, new_id, now, row_to_dict


def conv_id_for(user_id: str) -> str:
    return f"conv_{user_id}"


async def get_or_create_default_conversation(user_id: str) -> str:
    cid = conv_id_for(user_id)
    async with get_db() as db:
        await db.execute(
            "INSERT OR IGNORE INTO chat_conversations (id, user_id, created_at, updated_at) VALUES (?, ?, ?, ?)",
            (cid, user_id, now(), now()),
        )
        await db.commit()
    return cid


async def owns_conversation(user_id: str, conv_id: str) -> bool:
    async with get_db() as db:
        row = await (await db.execute("SELECT 1 FROM chat_conversations WHERE id = ? AND user_id = ?", (conv_id, user_id))).fetchone()
    return row is not None


async def get_message(message_id: str) -> dict | None:
    async with get_db() as db:
        row = await (await db.execute("SELECT id, user_id, role, status FROM chat_messages WHERE id = ?", (message_id,))).fetchone()
    return row_to_dict(row) if row else None


async def save_user_message(user_id: str, conv_id: str, client_id: str, text: str) -> float:
    ts = now()
    async with get_db() as db:
        await db.execute(
            "INSERT INTO chat_messages (id, conversation_id, user_id, role, text, status, last_seq, created_at) "
            "VALUES (?, ?, ?, 'user', ?, NULL, 0, ?)",
            (client_id, conv_id, user_id, encrypt(text), ts),
        )
        await db.execute("UPDATE chat_conversations SET updated_at = ? WHERE id = ?", (ts, conv_id))
        await db.commit()
    return ts


async def create_assistant(user_id: str, conv_id: str, message_id: str, reply_to: str) -> float:
    ts = now()
    async with get_db() as db:
        await db.execute(
            "INSERT INTO chat_messages (id, conversation_id, user_id, role, text, status, last_seq, reply_to, created_at) "
            "VALUES (?, ?, ?, 'assistant', ?, 'streaming', 0, ?, ?)",
            (message_id, conv_id, user_id, encrypt(""), reply_to, ts),
        )
        await db.commit()
    return ts


async def save_assistant(message_id: str, text: str, last_seq: int, tools: list[dict], status: str) -> None:
    async with get_db() as db:
        await db.execute(
            "UPDATE chat_messages SET text = ?, last_seq = ?, tools_json = ?, status = ? WHERE id = ?",
            (encrypt(text), last_seq, encrypt(dumps(tools)) if tools else None, status, message_id),
        )
        await db.commit()


async def mark_streaming_interrupted() -> int:
    """After a restart no generation is running: anything still 'streaming' was cut off."""
    async with get_db() as db:
        cur = await db.execute("UPDATE chat_messages SET status = 'interrupted' WHERE status = 'streaming'")
        await db.commit()
        return cur.rowcount


def _wire(row: dict) -> dict[str, Any]:
    msg: dict[str, Any] = {"id": row["id"], "role": row["role"], "text": decrypt(row["text"]), "created_at": iso(row["created_at"])}
    if row["role"] == "assistant":
        msg["status"] = row["status"] or "complete"
        if row["status"] == "streaming":
            msg["last_seq"] = row["last_seq"]
        if row["tools_json"]:
            msg["tools"] = loads(decrypt(row["tools_json"]), [])
    return msg


async def history(user_id: str, conv_id: str, limit: int, before: str | None) -> tuple[list[dict], bool]:
    limit = max(1, min(int(limit), 200))
    async with get_db() as db:
        args: list[Any] = [conv_id, user_id]
        cond = ""
        if before:
            b = await (await db.execute("SELECT created_at FROM chat_messages WHERE id = ? AND user_id = ?", (before, user_id))).fetchone()
            if b:
                cond = " AND created_at < ?"
                args.append(b["created_at"])
        args.append(limit + 1)
        rows = await (await db.execute(
            "SELECT * FROM chat_messages WHERE conversation_id = ? AND user_id = ?" + cond +
            " ORDER BY created_at DESC, rowid DESC LIMIT ?", args)).fetchall()
    has_more = len(rows) > limit
    rows = rows[:limit][::-1]
    return [_wire(row_to_dict(r)) for r in rows], has_more


async def recent_for_model(conv_id: str, limit: int = 20, max_chars: int = 12000) -> list[dict[str, str]]:
    """Plain {role, content} turns for the model, oldest first, trimmed to a character budget."""
    async with get_db() as db:
        rows = await (await db.execute(
            "SELECT role, text, status FROM chat_messages WHERE conversation_id = ? AND role IN ('user','assistant') "
            "AND (status IS NULL OR status != 'streaming') ORDER BY created_at DESC, rowid DESC LIMIT ?",
            (conv_id, limit))).fetchall()
    out, used = [], 0
    for r in rows:
        text = decrypt(r["text"])
        if not text.strip():
            continue
        used += len(text)
        if used > max_chars and out:
            break
        out.append({"role": r["role"], "content": text})
    return out[::-1]


async def update_tool_state(message_id: str, call_id: str, state: str, summary: str) -> list[dict] | None:
    async with get_db() as db:
        row = await (await db.execute("SELECT tools_json FROM chat_messages WHERE id = ?", (message_id,))).fetchone()
        if not row or not row["tools_json"]:
            return None
        tools = loads(decrypt(row["tools_json"]), [])
        for t in tools:
            if t.get("call_id") == call_id:
                t["state"], t["summary"] = state, summary[:80]
        await db.execute("UPDATE chat_messages SET tools_json = ? WHERE id = ?", (encrypt(dumps(tools)), message_id))
        await db.commit()
    return tools


async def delete_conversation(user_id: str, conv_id: str) -> bool:
    async with get_db() as db:
        cur = await db.execute("DELETE FROM chat_conversations WHERE id = ? AND user_id = ?", (conv_id, user_id))
        if cur.rowcount:
            await db.execute("DELETE FROM chat_messages WHERE conversation_id = ? AND user_id = ?", (conv_id, user_id))
        await db.commit()
        return cur.rowcount > 0


async def purge_older_than(days: int) -> int:
    cutoff = time.time() - days * 86400
    async with get_db() as db:
        cur = await db.execute("DELETE FROM chat_messages WHERE created_at < ?", (cutoff,))
        await db.commit()
        return cur.rowcount
