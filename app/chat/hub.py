"""
In-memory chat hub: open sockets per user (fan-out), running generations per conversation,
rate limits, and housekeeping. One process only (see server.md section 8).
"""
from __future__ import annotations

import asyncio
import json
import time
import uuid
from dataclasses import dataclass, field
from typing import Any

from fastapi import WebSocket

from app.auth.ratelimit import SlidingWindow
from app.chat import protocol, store
from app.config import settings
from app.storage.db import get_db, iso

MAX_QUEUED_BYTES = 1024 * 1024


class Connection:
    """One WebSocket plus a bounded outgoing queue (backpressure -> close 1013)."""

    def __init__(self, ws: WebSocket, user_id: str, token_hash: str) -> None:
        self.ws, self.user_id, self.token_hash = ws, user_id, token_hash
        self.closed = False
        self._q: asyncio.Queue[str | None] = asyncio.Queue()
        self._queued = 0
        self._writer = asyncio.create_task(self._write_loop())

    def send(self, frame: dict[str, Any]) -> None:
        if self.closed:
            return
        data = json.dumps(frame, ensure_ascii=False)
        if self._queued + len(data) > MAX_QUEUED_BYTES:
            asyncio.create_task(self.close(1013))
            return
        self._queued += len(data)
        self._q.put_nowait(data)

    async def _write_loop(self) -> None:
        try:
            while True:
                data = await self._q.get()
                if data is None:
                    return
                self._queued -= len(data)
                await self.ws.send_text(data)
        except Exception:  # noqa: BLE001 - socket gone; receive loop will notice
            self.closed = True

    async def close(self, code: int) -> None:
        if self.closed:
            return
        self.closed = True
        self._q.put_nowait(None)
        try:
            await self.ws.close(code=code)
        except Exception:  # noqa: BLE001
            pass

    async def shutdown(self) -> None:
        self.closed = True
        self._q.put_nowait(None)
        try:
            await asyncio.wait_for(self._writer, timeout=1)
        except Exception:  # noqa: BLE001
            self._writer.cancel()


@dataclass
class GenState:
    user_id: str
    conv_id: str
    reply_to: str                     # the user message id (client_id)
    message_id: str                   # assistant message id
    task: asyncio.Task | None = None
    started: bool = False
    cancel_requested: bool = False
    text: str = ""                    # text already sent in deltas
    buffer: str = ""                  # text waiting for the next flush
    seq: int = 0
    tools: list[dict[str, Any]] = field(default_factory=list)
    last_flush: float = 0.0
    last_persist: float = 0.0


class ChatHub:
    def __init__(self) -> None:
        self.conns: dict[str, list[Connection]] = {}
        self.running: dict[str, GenState] = {}           # conversation id -> state
        self.send_limiter = SlidingWindow(settings.chat_rate_limit_per_min, 60)
        self.connect_limiter = SlidingWindow(settings.ws_connect_per_min_per_ip, 60)

    # ---- sockets -------------------------------------------------------------------------
    async def add(self, conn: Connection) -> None:
        lst = self.conns.setdefault(conn.user_id, [])
        lst.append(conn)
        while len(lst) > settings.chat_max_sockets_per_user:
            await lst.pop(0).close(4429)   # oldest; the app backs off >= 30 s on 4429

    def remove(self, conn: Connection) -> None:
        lst = self.conns.get(conn.user_id, [])
        if conn in lst:
            lst.remove(conn)
        if not lst:
            self.conns.pop(conn.user_id, None)

    def broadcast(self, user_id: str, frame: dict[str, Any], exclude: Connection | None = None) -> None:
        for c in list(self.conns.get(user_id, [])):
            if c is not exclude:
                c.send(frame)

    async def close_token(self, token_hash: str, code: int) -> None:
        for lst in list(self.conns.values()):
            for c in list(lst):
                if c.token_hash == token_hash:
                    await c.close(code)

    # ---- generations ---------------------------------------------------------------------
    def is_busy(self, conv_id: str) -> bool:
        return conv_id in self.running

    def live(self, message_id: str) -> GenState | None:
        return next((s for s in self.running.values() if s.message_id == message_id), None)

    def reserve(self, user_id: str, conv_id: str, reply_to: str) -> GenState:
        """Synchronous (no await) so two sockets cannot both pass the busy check."""
        st = GenState(user_id=user_id, conv_id=conv_id, reply_to=reply_to, message_id="msg_" + uuid.uuid4().hex[:12])
        self.running[conv_id] = st
        return st

    def release(self, st: GenState) -> None:
        if self.running.get(st.conv_id) is st:
            del self.running[st.conv_id]

    async def begin(self, st: GenState) -> None:
        from app.chat import agent  # late: agent imports this module

        created = await store.create_assistant(st.user_id, st.conv_id, st.message_id, st.reply_to)
        self.broadcast(st.user_id, protocol.assistant_start(st.message_id, st.reply_to, iso(created) or ""))
        st.task = asyncio.create_task(agent.run(self, st))

    def cancel(self, user_id: str, message_id: str | None, reply_to: str | None) -> bool:
        for st in self.running.values():
            if st.user_id == user_id and ((message_id and st.message_id == message_id) or (reply_to and st.reply_to == reply_to)):
                st.cancel_requested = True
                if st.task and st.started:
                    st.task.cancel()
                return True
        return False

    async def cancel_all_for_user(self, user_id: str) -> None:
        for st in list(self.running.values()):
            if st.user_id == user_id:
                self.cancel(user_id, st.message_id, None)
                if st.task:
                    try:
                        await asyncio.wait_for(asyncio.shield(st.task), timeout=3)
                    except Exception:  # noqa: BLE001
                        pass

    async def on_approval_decided(self, approval: dict[str, Any], approved: bool, ok: bool) -> None:
        """Tell the chat the gate was decided. Never includes the tool's data."""
        mid, cid, uid = approval.get("chat_message_id"), approval.get("chat_call_id"), approval.get("user_id")
        if not (mid and cid and uid):
            return
        state, summary = ("done", "Approved") if approved and ok else ("failed", "Approved, but it failed" if approved else "Denied")
        live = self.live(mid)
        if live:
            for t in live.tools:
                if t["call_id"] == cid:
                    t["state"], t["summary"] = state, summary
        await store.update_tool_state(mid, cid, state, summary)
        self.broadcast(uid, protocol.tool_status(mid, cid, approval["tool"], state, summary))

    # ---- housekeeping --------------------------------------------------------------------
    async def revalidate_sockets(self) -> None:
        """Close sockets whose token has expired or been revoked since they connected."""
        hashes = {c.token_hash for lst in self.conns.values() for c in lst}
        if not hashes:
            return
        async with get_db() as db:
            marks = ",".join("?" * len(hashes))
            rows = await (await db.execute(
                f"SELECT token_hash FROM user_tokens WHERE token_hash IN ({marks}) AND revoked_at IS NULL AND expires_at > ?",
                (*hashes, time.time()))).fetchall()
        valid = {r["token_hash"] for r in rows}
        for h in hashes - valid:
            await self.close_token(h, 4401)

    async def housekeeping(self) -> None:
        last_purge = 0.0
        while True:
            await asyncio.sleep(60)
            try:
                await self.revalidate_sockets()
                if time.time() - last_purge > 86400:
                    await store.purge_older_than(settings.chat_history_retention_days)
                    last_purge = time.time()
            except Exception:  # noqa: BLE001 - never let the janitor die
                pass


hub = ChatHub()
