from __future__ import annotations

from mcp.server.mcpserver import Context

from app.devices import registry
from app.mcp_tools.registry import mcp_server
from app.permissions.scopes import guarded


@mcp_server.tool()
@guarded("send_notification")
async def send_notification(ctx: Context, device_id: str, title: str, body: str) -> dict:
    """Send a notification to a specific device node. Delivered the next time that
    device checks in (at most ~30s later, per the heartbeat interval).

    Args:
        device_id: Target device id, from list_devices().
        title: Notification title.
        body: Notification body text.
    """
    device = await registry.get_device_context(device_id, telemetry_limit=0)
    if device is None:
        return {"status": "not_found", "device_id": device_id}
    result = await registry.queue_command(device_id, "notification", {"title": title, "body": body})
    return {"status": "queued", **result}
