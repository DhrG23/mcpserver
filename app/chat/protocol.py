"""Chat wire protocol (server.md section 3): client frame parsing + server frame builders."""
from __future__ import annotations

import json
from typing import Any

from pydantic import BaseModel, ConfigDict, Field, ValidationError

MAX_FRAME_BYTES = 1024 * 1024
PROTOCOL_VERSION = 1


class FrameError(Exception):
    def __init__(self, detail: str, client_id: str | None = None) -> None:
        self.detail, self.client_id = detail, client_id
        super().__init__(detail)


class _In(BaseModel):
    model_config = ConfigDict(extra="ignore")


class ChatSend(_In):
    client_id: str = Field(pattern=r"^[A-Za-z0-9_\-]{1,64}$")
    conversation_id: str | None = None
    text: str
    sent_at: str | None = None


class ChatCancel(_In):
    message_id: str | None = None
    reply_to: str | None = None


class HistoryGet(_In):
    conversation_id: str | None = None
    before: str | None = None
    limit: int = 50


_FRAMES: dict[str, type[_In]] = {"chat.send": ChatSend, "chat.cancel": ChatCancel, "history.get": HistoryGet}


def parse_client_frame(raw: str) -> tuple[str, _In]:
    """Return (type, model). Raises FrameError for non-JSON, non-objects, unknown types, bad fields."""
    if len(raw.encode("utf-8", "ignore")) > MAX_FRAME_BYTES:
        raise FrameError("Frame is too large.")
    try:
        obj = json.loads(raw)
    except ValueError:
        raise FrameError("Frames must be JSON.") from None
    if not isinstance(obj, dict) or not isinstance(obj.get("type"), str):
        raise FrameError("Frames must be JSON objects with a type.")
    cid = obj.get("client_id") if isinstance(obj.get("client_id"), str) else None
    model = _FRAMES.get(obj["type"])
    if model is None:
        raise FrameError("Unknown frame type.", cid)
    try:
        return obj["type"], model.model_validate(obj)
    except ValidationError:
        raise FrameError("Invalid fields in frame.", cid) from None


# ---- server -> client builders -------------------------------------------------------------

def ready(conversation_id: str, server_time: str, user_name: str, max_chars: int) -> dict[str, Any]:
    return {"type": "ready", "protocol_version": PROTOCOL_VERSION, "conversation_id": conversation_id,
            "server_time": server_time, "user_name": user_name, "max_message_chars": max_chars,
            "features": ["streaming", "tools", "history"]}


def error(code: str, detail: str, client_id: str | None = None, retry_after: int | None = None) -> dict[str, Any]:
    f: dict[str, Any] = {"type": "error", "code": code, "detail": detail}
    if client_id:
        f["client_id"] = client_id
    if retry_after is not None:
        f["retry_after"] = retry_after
    return f


def ack(client_id: str, created_at: str) -> dict[str, Any]:
    return {"type": "chat.ack", "client_id": client_id, "created_at": created_at}


def assistant_start(message_id: str, reply_to: str, created_at: str) -> dict[str, Any]:
    return {"type": "assistant.start", "message_id": message_id, "reply_to": reply_to, "created_at": created_at}


def assistant_delta(message_id: str, seq: int, text: str) -> dict[str, Any]:
    return {"type": "assistant.delta", "message_id": message_id, "seq": seq, "text": text}


def assistant_end(message_id: str, finish_reason: str, text: str | None = None) -> dict[str, Any]:
    f: dict[str, Any] = {"type": "assistant.end", "message_id": message_id, "finish_reason": finish_reason}
    if text is not None:
        f["text"] = text
    return f


def tool_status(message_id: str, call_id: str, name: str, state: str, summary: str) -> dict[str, Any]:
    return {"type": "tool.status", "message_id": message_id, "call_id": call_id, "name": name,
            "state": state, "summary": summary[:80]}
