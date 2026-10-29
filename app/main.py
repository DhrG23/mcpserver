"""
Entrypoint. Two ASGI apps in one process (single process = in-memory chat fan-out works):

  MCP_PORT     (8000)  /mcp                       MCP Streamable HTTP  <- Alexa+, Nemotron, Ollama agent
  GATEWAY_PORT (8001)  /auth/* /heartbeat /devices* /approvals* /chat/ws /healthz  <- the Node app

Both bind to BIND_HOST (default 127.0.0.1). Put Caddy in front for TLS; see docker/.
"""
from __future__ import annotations

import app.config  # noqa: F401  (must be first: loads .env)

import asyncio
import contextlib
import logging
import os

import uvicorn
from fastapi import FastAPI, Request
from fastapi.exceptions import RequestValidationError
from fastapi.responses import JSONResponse

from app.mcp_tools.registry import mcp_server
from app.mcp_tools import memory, tasks, calendar, web, files, device, notify, automation  # noqa: F401
from app.auth.routes import router as auth_router
from app.chat import store as chat_store
from app.chat.hub import hub
from app.chat.routes import router as chat_router
from app.config import settings
from app.devices.gateway import router as devices_router
from app.permissions.admin import router as approvals_router
from app.permissions.scopes import seed_permissions

log = logging.getLogger("personal_ai")

mcp_app = mcp_server.streamable_http_app(streamable_http_path="/mcp", stateless_http=True, host=settings.bind_host)


@contextlib.asynccontextmanager
async def lifespan(_: FastAPI):
    await seed_permissions()
    interrupted = await chat_store.mark_streaming_interrupted()
    if interrupted:
        log.info("marked %d unfinished chat answers as interrupted", interrupted)
    janitor = asyncio.create_task(hub.housekeeping())
    try:
        yield
    finally:
        janitor.cancel()


gateway_app = FastAPI(title="Personal AI - Gateway", lifespan=lifespan)
for r in (auth_router, devices_router, approvals_router, chat_router):
    gateway_app.include_router(r)


@gateway_app.exception_handler(RequestValidationError)
async def _validation(_: Request, exc: RequestValidationError):
    """The Node app expects {"detail": "<string>"} for every error."""
    first = exc.errors()[0] if exc.errors() else {}
    field = ".".join(str(p) for p in first.get("loc", []) if p != "body")
    return JSONResponse({"detail": f"Invalid {field or 'request'}: {first.get('msg', 'bad value')}"}, status_code=422)


@gateway_app.get("/healthz")
async def healthz():
    return {"status": "ok"}


async def _run() -> None:
    await seed_permissions()   # MCP calls can arrive before the gateway lifespan finishes
    common = dict(host=settings.bind_host, log_level="info", proxy_headers=True,
                  forwarded_allow_ips=settings.forwarded_allow_ips)
    mcp_cfg = uvicorn.Config(mcp_app, port=settings.mcp_port, **common)
    gw_cfg = uvicorn.Config(gateway_app, port=settings.gateway_port, ws="websockets", ws_max_size=1024 * 1024,
                            ws_ping_interval=25, ws_ping_timeout=60, **common)
    await asyncio.gather(uvicorn.Server(mcp_cfg).serve(), uvicorn.Server(gw_cfg).serve())


def main() -> None:
    asyncio.run(_run())


if __name__ == "__main__":
    main()
