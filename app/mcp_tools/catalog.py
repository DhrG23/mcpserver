"""
In-process access to the MCP tools, used by the chat agent and by approval replay.

Every call still goes through guarded(): we build a context whose Authorization header
resolves to the chosen caller (e.g. 'nemotron'), so allow / approval / deny and the audit
log apply exactly as for an outside MCP client. Chat gains no extra access.
"""
from __future__ import annotations

import inspect
import typing
from types import SimpleNamespace
from typing import Any, Callable

from pydantic import create_model

from app.permissions.scopes import resolve_caller, token_for_caller

TOOL_MODULES = ["memory", "tasks", "calendar", "web", "files", "device", "notify", "automation"]
TOOL_NAMES = [
    "search_memory", "remember", "forget", "get_tasks", "create_task", "complete_task",
    "get_calendar", "create_event", "find_free_time", "search_web", "fetch_webpage",
    "search_files", "read_file", "list_devices", "get_device_context", "get_location",
    "send_notification", "create_automation", "get_automations",
]


def _load() -> dict[str, Callable]:
    import importlib

    found: dict[str, Callable] = {}
    for mod_name in TOOL_MODULES:
        mod = importlib.import_module(f"app.mcp_tools.{mod_name}")
        for name in TOOL_NAMES:
            fn = getattr(mod, name, None)
            if fn is None:
                continue
            if not callable(fn):  # some SDK versions return a Tool object from @tool()
                fn = getattr(fn, "fn", None)
            if callable(fn):
                found[name] = fn
    return found


_TOOLS: dict[str, Callable] | None = None


def tools() -> dict[str, Callable]:
    global _TOOLS
    if _TOOLS is None:
        _TOOLS = _load()
    return _TOOLS


def internal_ctx(caller: str) -> SimpleNamespace:
    token = token_for_caller(caller)
    if token is None:
        raise RuntimeError(f"No token configured for caller '{caller}'")
    ctx = SimpleNamespace(headers={"authorization": f"Bearer {token}"})
    assert resolve_caller(ctx.headers) == caller
    return ctx


def _unwrapped(fn: Callable) -> Callable:
    return inspect.unwrap(fn)


def json_schema_for(name: str) -> dict[str, Any]:
    """JSON schema of a tool's arguments, derived from its signature (ctx excluded)."""
    orig = _unwrapped(tools()[name])
    hints = typing.get_type_hints(orig)
    fields: dict[str, Any] = {}
    for pname, param in inspect.signature(orig).parameters.items():
        if pname == "ctx":
            continue
        ann = hints.get(pname, Any)
        fields[pname] = (ann, ... if param.default is inspect.Parameter.empty else param.default)
    schema = create_model(f"{name}_args", **fields).model_json_schema()
    schema.pop("title", None)
    for prop in schema.get("properties", {}).values():
        prop.pop("title", None)
    return schema


def llm_tool_specs() -> list[dict[str, Any]]:
    """OpenAI/Ollama-style function specs for every available tool."""
    specs = []
    for name in sorted(tools()):
        doc = inspect.getdoc(_unwrapped(tools()[name])) or name
        specs.append({"type": "function", "function": {
            "name": name, "description": doc.split("\n\nArgs:")[0].strip()[:600], "parameters": json_schema_for(name)}})
    return specs


async def call_guarded(caller: str, name: str, arguments: dict[str, Any]) -> dict[str, Any]:
    """Run a tool through guarded(). Returns the tool's dict (or an approval_required / denied dict)."""
    fn = tools().get(name)
    if fn is None:
        return {"status": "error", "message": f"Unknown tool '{name}'"}
    return await fn(internal_ctx(caller), **arguments)


async def replay_unguarded(caller: str, name: str, args: dict[str, Any]) -> dict[str, Any]:
    """Re-run an APPROVED call with its stored arguments, skipping the (already satisfied) gate."""
    fn = tools().get(name)
    if fn is None:
        return {"status": "error", "message": f"Unknown tool '{name}'"}
    return await _unwrapped(fn)(internal_ctx(caller), *args.get("args", []), **args.get("kwargs", {}))
