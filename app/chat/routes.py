"""GET /chat/ws (WebSocket) and DELETE /chat/conversations/{id}."""
from __future__ import annotations

import time
from datetime import datetime, timezone

from fastapi import APIRouter, Depends, HTTPException, WebSocket
from fastapi.responses import JSONResponse

from app.auth.deps import current_user
from app.auth.security import AuthedUser, bearer_from_header, user_for_token
from app.chat import protocol, store
from app.chat.hub import Connection, hub
from app.config import settings
from app.storage.db import iso

router = APIRouter(tags=["chat"])


def _now_iso() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


async def _deny(ws: WebSocket, status: int, detail: str) -> None:
    """Refuse the upgrade with a real HTTP status (401/429) when the ASGI server supports it."""
    try:
        await ws.send_denial_response(JSONResponse({"detail": detail}, status_code=status))
    except Exception:  # noqa: BLE001 - server lacks the extension: fall back to a pre-accept close (-> 403)
        await ws.close(code=1008)


@router.websocket("/chat/ws")
async def chat_ws(ws: WebSocket) -> None:
    ip = ws.client.host if ws.client else "unknown"
    wait = hub.connect_limiter.hit(ip)
    if wait:
        return await _deny(ws, 429, f"Too many connection attempts. Try again in {wait} s.")
    token = bearer_from_header(ws.headers.get("authorization"))     # header only; never the query string
    user = await user_for_token(token) if token else None
    if user is None:
        return await _deny(ws, 401, "Session rejected.")

    await ws.accept()
    conn = Connection(ws, user.id, user.token_hash)
    conv_id = await store.get_or_create_default_conversation(user.id)
    conn.send(protocol.ready(conv_id, _now_iso(), user.name, settings.chat_max_message_chars))
    await hub.add(conn)
    try:
        while True:
            msg = await ws.receive()
            if msg["type"] == "websocket.disconnect":
                break
            raw = msg.get("text")
            if raw is None:   # binary frame
                conn.send(protocol.error("invalid_frame", "Binary frames are not supported."))
                continue
            try:
                kind, frame = protocol.parse_client_frame(raw)
            except protocol.FrameError as e:
                conn.send(protocol.error("invalid_frame", e.detail, e.client_id))
                continue
            if kind == "history.get":
                await _history(conn, user, conv_id, frame)
            elif kind == "chat.send":
                await _send(conn, user, conv_id, frame)
            elif kind == "chat.cancel":
                hub.cancel(user.id, frame.message_id, frame.reply_to)
    finally:
        hub.remove(conn)          # running generations deliberately keep going (server.md 4.6)
        await conn.shutdown()


async def _history(conn: Connection, user: AuthedUser, conv_id: str, frame: protocol.HistoryGet) -> None:
    if frame.conversation_id and frame.conversation_id != conv_id:
        conn.send(protocol.error("invalid_frame", "Unknown conversation."))
        return
    messages, has_more = await store.history(user.id, conv_id, frame.limit, frame.before)
    for m in messages:                                   # overlay the live state of a running answer
        live = hub.live(m["id"])
        if live and m["role"] == "assistant":
            m.update(text=live.text, status="streaming", last_seq=live.seq)
            if live.tools:
                m["tools"] = [dict(t) for t in live.tools]
    conn.send({"type": "history", "conversation_id": conv_id, "has_more": has_more, "messages": messages})


async def _send(conn: Connection, user: AuthedUser, conv_id: str, frame: protocol.ChatSend) -> None:
    cid = frame.client_id
    if frame.conversation_id and frame.conversation_id != conv_id:
        conn.send(protocol.error("invalid_frame", "Unknown conversation.", cid))
        return

    existing = await store.get_message(cid)                       # 1. idempotent retry
    if existing is not None:
        if existing["user_id"] != user.id:
            conn.send(protocol.error("invalid_frame", "That message id is not available.", cid))
        else:
            conn.send(protocol.ack(cid, _now_iso()))
        return

    text = frame.text
    if not text.strip():
        conn.send(protocol.error("invalid_frame", "Message is empty.", cid))
        return
    if len(text) > settings.chat_max_message_chars:
        conn.send(protocol.error("message_too_long", f"Messages are limited to {settings.chat_max_message_chars} characters.", cid))
        return
    wait = hub.send_limiter.hit(user.id)
    if wait:
        conn.send(protocol.error("rate_limited", "You're sending messages too quickly.", cid, retry_after=wait))
        return
    if hub.is_busy(conv_id):
        conn.send(protocol.error("busy", "Still answering the previous message.", cid))
        return

    st = hub.reserve(user.id, conv_id, cid)                      # no await between check and reserve
    try:
        created = await store.save_user_message(user.id, conv_id, cid, text)
    except Exception:  # noqa: BLE001
        hub.release(st)
        conn.send(protocol.error("internal", "Couldn't save that message.", cid))
        return
    conn.send(protocol.ack(cid, iso(created) or _now_iso()))     # 2. ack before any model call
    hub.broadcast(user.id, {"type": "message.created", "message": {
        "id": cid, "role": "user", "text": text, "created_at": iso(created)}}, exclude=conn)
    try:
        await hub.begin(st)
    except Exception:  # noqa: BLE001
        hub.release(st)
        conn.send(protocol.error("internal", "Couldn't start the answer.", cid))


@router.delete("/chat/conversations/{conversation_id}")
async def delete_conversation(conversation_id: str, user: AuthedUser = Depends(current_user)):
    if not await store.owns_conversation(user.id, conversation_id):
        raise HTTPException(status_code=404, detail="Conversation not found.")
    await hub.cancel_all_for_user(user.id)
    await store.delete_conversation(user.id, conversation_id)
    return {"status": "ok"}
