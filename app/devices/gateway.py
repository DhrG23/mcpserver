from __future__ import annotations

from fastapi import APIRouter, Header, HTTPException
from pydantic import BaseModel

from app.devices import registry

router = APIRouter(prefix="/devices", tags=["devices"])


class RegisterRequest(BaseModel):
    name: str          # e.g. "arch-desktop", "pixel-8"
    platform: str      # linux | android | ios | ipados | macos
    owner: str          # human owner label, e.g. "you" / "teammate"


class HeartbeatRequest(BaseModel):
    battery: float | None = None
    lat: float | None = None
    lon: float | None = None


class TelemetryRequest(BaseModel):
    kind: str           # screenshot | notification | battery | location | sensor | status
    payload: dict        # arbitrary JSON; put base64 blobs under payload["data_b64"]


def _extract_token(authorization: str | None) -> str:
    if not authorization or not authorization.startswith("Bearer "):
        raise HTTPException(status_code=401, detail="Missing device bearer token")
    return authorization.removeprefix("Bearer ").strip()


@router.post("/register")
async def register(body: RegisterRequest):
    """One-time call a node app makes on first setup. Store the returned token securely
    on-device — it's the only credential used for heartbeat/telemetry after this."""
    result = await registry.register_device(body.name, body.platform, body.owner)
    return result


@router.post("/heartbeat")
async def heartbeat(body: HeartbeatRequest, authorization: str | None = Header(default=None)):
    """Node apps call this every ~30s. Cheap fields (battery/location) can ride along here
    instead of a separate telemetry push."""
    token = _extract_token(authorization)
    result = await registry.heartbeat(token, body.battery, body.lat, body.lon)
    if result is None:
        raise HTTPException(status_code=401, detail="Unknown device token")
    # Piggyback any queued commands (notifications, screenshot requests, ...) on the
    # heartbeat response so nodes never need a separate long-poll connection.
    result["pending_commands"] = await registry.pop_pending_commands(result["device_id"])
    return result


@router.post("/telemetry")
async def telemetry(body: TelemetryRequest, authorization: str | None = Header(default=None)):
    """Push a heavier or less frequent payload: a screenshot, a batch of notifications, etc."""
    token = _extract_token(authorization)
    result = await registry.push_telemetry(token, body.kind, body.payload)
    if result is None:
        raise HTTPException(status_code=401, detail="Unknown device token")
    return result


@router.get("")
async def list_devices_route():
    """Human/debug view of registered devices. The MCP tool list_devices() wraps this same data."""
    return await registry.list_devices()
