from __future__ import annotations

from mcp.server.mcpserver import Context

from app.devices import registry
from app.mcp_tools.registry import mcp_server
from app.permissions.scopes import guarded


@mcp_server.tool()
@guarded("list_devices")
async def list_devices(ctx: Context) -> dict:
    """List all registered device nodes and their online/offline status."""
    devices = await registry.list_devices()
    return {"status": "ok", "count": len(devices), "devices": devices}


@mcp_server.tool()
@guarded("get_device_context")
async def get_device_context(ctx: Context, device_id: str, telemetry_limit: int = 10) -> dict:
    """Get a device's current state and recent telemetry (battery, location, screenshots,
    notifications, etc.) as last reported by its node app.

    Args:
        device_id: The device id from list_devices().
        telemetry_limit: How many recent telemetry entries to include.
    """
    device = await registry.get_device_context(device_id, telemetry_limit)
    if device is None:
        return {"status": "not_found", "device_id": device_id}
    return {"status": "ok", "device": device}
