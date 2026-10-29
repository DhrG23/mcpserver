"""
Model backends for chat. All three expose the same tiny interface:

    async for kind, value in provider.stream(messages, tools):   # ("text", str) | ("calls", [ToolCall])
    provider.assistant_message(text, calls) / provider.tool_message(call, content)

  ollama  local Ollama  (/api/chat, NDJSON)
  openai  any OpenAI-compatible endpoint, e.g. Nebius AI Studio for Nemotron (/chat/completions, SSE)
  echo    DEVELOPMENT ONLY: no model; lets you test the WebSocket, streaming, cancel and approvals
"""
from __future__ import annotations

import asyncio
import json
from dataclasses import dataclass
from typing import Any, AsyncIterator

import httpx

from app.config import settings


@dataclass
class ToolCall:
    id: str
    name: str
    arguments: dict[str, Any]


def _json_args(raw: Any) -> dict[str, Any]:
    if isinstance(raw, dict):
        return raw
    try:
        val = json.loads(raw or "{}")
        return val if isinstance(val, dict) else {}
    except ValueError:
        return {}


class OllamaProvider:
    def __init__(self) -> None:
        self.base = (settings.chat_llm_base_url or "http://127.0.0.1:11434").rstrip("/")
        self.model = settings.chat_llm_model or "qwen3.5:2b"

    async def stream(self, messages, tools) -> AsyncIterator[tuple[str, Any]]:
        body = {"model": self.model, "messages": messages, "tools": tools, "stream": True,
                "think": settings.chat_ollama_think}
        calls: list[ToolCall] = []
        async with httpx.AsyncClient(timeout=httpx.Timeout(settings.chat_model_timeout_s, connect=10)) as client:
            async with client.stream("POST", f"{self.base}/api/chat", json=body) as resp:
                if resp.status_code >= 400:
                    raise RuntimeError(f"ollama http {resp.status_code}")
                async for line in resp.aiter_lines():
                    if not line.strip():
                        continue
                    chunk = json.loads(line)
                    if chunk.get("error"):
                        raise RuntimeError("ollama error")
                    msg = chunk.get("message") or {}
                    if msg.get("content"):
                        yield "text", msg["content"]
                    for i, tc in enumerate(msg.get("tool_calls") or []):
                        fn = tc.get("function") or {}
                        calls.append(ToolCall(f"c{len(calls) + 1}", fn.get("name", ""), _json_args(fn.get("arguments"))))
        if calls:
            yield "calls", calls

    def assistant_message(self, text: str, calls: list[ToolCall]) -> dict:
        return {"role": "assistant", "content": text,
                "tool_calls": [{"function": {"name": c.name, "arguments": c.arguments}} for c in calls]}

    def tool_message(self, call: ToolCall, content: str) -> dict:
        return {"role": "tool", "tool_name": call.name, "content": content}


class OpenAIProvider:
    def __init__(self) -> None:
        if not settings.chat_llm_base_url or not settings.chat_llm_model:
            raise RuntimeError("CHAT_LLM_BASE_URL and CHAT_LLM_MODEL must be set for the openai provider")
        self.base = settings.chat_llm_base_url.rstrip("/")
        self.model = settings.chat_llm_model

    async def stream(self, messages, tools) -> AsyncIterator[tuple[str, Any]]:
        headers = {"Authorization": f"Bearer {settings.chat_llm_api_key}"} if settings.chat_llm_api_key else {}
        body = {"model": self.model, "messages": messages, "tools": tools, "stream": True}
        acc: dict[int, dict[str, str]] = {}
        async with httpx.AsyncClient(timeout=httpx.Timeout(settings.chat_model_timeout_s, connect=10)) as client:
            async with client.stream("POST", f"{self.base}/chat/completions", json=body, headers=headers) as resp:
                if resp.status_code >= 400:
                    raise RuntimeError(f"llm http {resp.status_code}")
                async for line in resp.aiter_lines():
                    if not line.startswith("data:"):
                        continue
                    data = line[5:].strip()
                    if data == "[DONE]":
                        break
                    choices = json.loads(data).get("choices") or []
                    if not choices:
                        continue
                    delta = choices[0].get("delta") or {}
                    if delta.get("content"):
                        yield "text", delta["content"]
                    for tc in delta.get("tool_calls") or []:
                        slot = acc.setdefault(tc.get("index", 0), {"id": "", "name": "", "args": ""})
                        slot["id"] = tc.get("id") or slot["id"]
                        fn = tc.get("function") or {}
                        slot["name"] += fn.get("name") or ""
                        slot["args"] += fn.get("arguments") or ""
        if acc:
            yield "calls", [ToolCall(s["id"] or f"c{i + 1}", s["name"], _json_args(s["args"]))
                            for i, s in sorted(acc.items())]

    def assistant_message(self, text: str, calls: list[ToolCall]) -> dict:
        return {"role": "assistant", "content": text or None,
                "tool_calls": [{"id": c.id, "type": "function",
                                "function": {"name": c.name, "arguments": json.dumps(c.arguments)}} for c in calls]}

    def tool_message(self, call: ToolCall, content: str) -> dict:
        return {"role": "tool", "tool_call_id": call.id, "content": content}


class EchoProvider:
    """Scripted stand-in. Mention 'location' to trigger the approval-gated get_location tool,
    'device' to call list_devices; otherwise it just streams the user's words back."""

    async def stream(self, messages, tools) -> AsyncIterator[tuple[str, Any]]:
        last = messages[-1]
        if last["role"] == "tool":
            reply = "I ran the tool. Result: " + str(last["content"])[:160]
        else:
            user = str(last.get("content", ""))
            low = user.lower()
            if "location" in low:
                yield "calls", [ToolCall("c1", "get_location", {"device_id": "unknown"})]
                return
            if "device" in low:
                yield "calls", [ToolCall("c1", "list_devices", {})]
                return
            reply = "Echo: " + user
        for word in reply.split(" "):
            yield "text", word + " "
            await asyncio.sleep(0.03)

    def assistant_message(self, text: str, calls: list[ToolCall]) -> dict:
        return {"role": "assistant", "content": text}

    def tool_message(self, call: ToolCall, content: str) -> dict:
        return {"role": "tool", "content": content}


def get_provider():
    return {"ollama": OllamaProvider, "openai": OpenAIProvider, "echo": EchoProvider}.get(
        settings.chat_llm_provider, OllamaProvider)()
