"""
Entrypoint for the Personal AI MCP server.

Runs two ASGI apps side by side in one process:
  - MCP streamable-HTTP app  (port MCP_PORT, default 8000) -> what Alexa+ / Nemotron talk to
  - Device gateway REST app  (port GATEWAY_PORT, default 8001) -> what node apps talk to

Kept as two apps deliberately (rather than mounting one inside the other) to
avoid ASGI lifespan-composition edge cases between FastAPI and the MCP SDK's
session manager. Put a reverse proxy (Caddy/nginx) in front in production;
see docker/Caddyfile.
"""
from __future__ import annotations

import asyncio
import os

import uvicorn
from fastapi import FastAPI

# Import tool modules for their registration side-effects (each module calls
# @mcp_server.tool() at import time). The import order doesn't matter.
from app.mcp_tools.registry import mcp_server
from app.mcp_tools import memory, tasks, calendar, web, files, device, notify, automation  # noqa: F401
from app.permissions.scopes import seed_permissions
from app.devices.gateway import router as devices_router
from app.permissions.admin import router as approvals_router

MCP_PORT = int(os.environ.get("MCP_PORT", 8000))
GATEWAY_PORT = int(os.environ.get("GATEWAY_PORT", 8001))
HOST = os.environ.get("BIND_HOST", "0.0.0.0")

mcp_app = mcp_server.streamable_http_app(streamable_http_path="/mcp", stateless_http=True, host=HOST)

gateway_app = FastAPI(title="Personal AI - Device Gateway")
gateway_app.include_router(devices_router)
gateway_app.include_router(approvals_router)


@gateway_app.get("/healthz")
async def healthz():
    return {"status": "ok"}


async def _run() -> None:
    await seed_permissions()

    mcp_config = uvicorn.Config(mcp_app, host=HOST, port=MCP_PORT, log_level="info")
    gateway_config = uvicorn.Config(gateway_app, host=HOST, port=GATEWAY_PORT, log_level="info")

    await asyncio.gather(
        uvicorn.Server(mcp_config).serve(),
        uvicorn.Server(gateway_config).serve(),
    )


def main() -> None:
    asyncio.run(_run())


if __name__ == "__main__":
    main()
