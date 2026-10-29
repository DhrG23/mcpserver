"""
Device REST routes.

Two generations live side by side:
  * Node app (user session token):  POST /heartbeat, GET /devices, GET|PATCH|DELETE /devices/{id},
                                    POST /devices/{id}/commands
  * Legacy standalone nodes (per-device token): POST /devices/register|heartbeat|telemetry
"""
from __future__ import annotations

from datetime import datetime, timezone
from typing import Any, Literal

from fastapi import APIRouter, Depends, Header, HTTPException, Request
from pydantic import BaseModel, ConfigDict, Field

from app.auth.deps import Principal, current_user, user_or_admin
from app.auth.security import AuthedUser
from app.devices import registry

router = APIRouter(tags=["devices"])

MAX_SNAPSHOT_BYTES = 256 * 1024


def _now_iso() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


# ---------------------------------------------------------------- Node app --------------

@router.post("/heartbeat")
async def app_heartbeat(request: Request, user: AuthedUser = Depends(current_user),
                        x_device_id: str | None = Header(default=None)):
    """The app's 'Sync now'. Body = DeviceSnapshot JSON (schema_version 4); stored encrypted."""
    raw = await request.body()
    if len(raw) > MAX_SNAPSHOT_BYTES:
        raise HTTPException(status_code=422, detail="Snapshot is too large.")
    try:
        body = await request.json()
    except Exception:  # noqa: BLE001
        raise HTTPException(status_code=422, detail="Body must be a JSON object.") from None
    if not isinstance(body, dict):
        raise HTTPException(status_code=422, detail="Body must be a JSON object.")
    device = await registry.upsert_app_device(user.id, user.name, body, x_device_id)
    await registry.record_snapshot(device["id"], body)
    return {"status": "ok", "device_id": device["id"], "server_time": _now_iso(),
            "pending_commands": await registry.pop_pending_commands(device["id"])}


@router.get("/devices")
async def list_my_devices(user: AuthedUser = Depends(current_user)):
    return [registry.public_device(d) for d in await registry.user_devices(user.id)]


class DevicePatch(BaseModel):
    model_config = ConfigDict(extra="ignore")
    name: str = Field(min_length=1, max_length=120)


class CommandBody(BaseModel):
    model_config = ConfigDict(extra="ignore")
    kind: Literal["notification", "request_screenshot", "request_sync"]
    payload: dict[str, Any] = Field(default_factory=dict)


@router.get("/devices/{device_id}")
async def get_my_device(device_id: str, user: AuthedUser = Depends(current_user)):
    d = await registry.user_device(user.id, device_id)
    if d is None:
        raise HTTPException(status_code=404, detail="Device not found.")
    return {**registry.public_device(d), "snapshot": await registry.latest_snapshot(device_id)}


@router.patch("/devices/{device_id}")
async def rename_my_device(device_id: str, body: DevicePatch, user: AuthedUser = Depends(current_user)):
    if not await registry.rename_device(user.id, device_id, body.name.strip()):
        raise HTTPException(status_code=404, detail="Device not found.")
    return registry.public_device((await registry.user_device(user.id, device_id)))


@router.delete("/devices/{device_id}")
async def delete_my_device(device_id: str, user: AuthedUser = Depends(current_user)):
    if not await registry.delete_device(user.id, device_id):
        raise HTTPException(status_code=404, detail="Device not found.")
    return {"status": "ok"}


@router.post("/devices/{device_id}/commands")
async def send_command(device_id: str, body: CommandBody, user: AuthedUser = Depends(current_user)):
    if await registry.user_device(user.id, device_id) is None:
        raise HTTPException(status_code=404, detail="Device not found.")
    if len(str(body.payload)) > 4000:
        raise HTTPException(status_code=422, detail="Command payload is too large.")
    return {"status": "queued", **await registry.queue_command(device_id, body.kind, body.payload)}


# ---------------------------------------------------------------- Legacy nodes ----------

class RegisterRequest(BaseModel):
    name: str
    platform: str
    owner: str


class HeartbeatRequest(BaseModel):
    battery: float | None = None
    lat: float | None = None
    lon: float | None = None


class TelemetryRequest(BaseModel):
    kind: str
    payload: dict


def _extract_token(authorization: str | None) -> str:
    if not authorization or not authorization.startswith("Bearer "):
        raise HTTPException(status_code=401, detail="Missing device bearer token")
    return authorization.removeprefix("Bearer ").strip()


@router.post("/devices/register")
async def register(body: RegisterRequest, _: Principal = Depends(user_or_admin)):
    """Mint a per-device token for a standalone node. Needs a signed-in user (or the admin token) so
    strangers who can reach the server cannot create devices."""
    return await registry.register_device(body.name, body.platform, body.owner)


@router.post("/devices/heartbeat")
async def heartbeat(body: HeartbeatRequest, authorization: str | None = Header(default=None)):
    result = await registry.heartbeat(_extract_token(authorization), body.battery, body.lat, body.lon)
    if result is None:
        raise HTTPException(status_code=401, detail="Unknown device token")
    result["pending_commands"] = await registry.pop_pending_commands(result["device_id"])
    return result


@router.post("/devices/telemetry")
async def telemetry(body: TelemetryRequest, authorization: str | None = Header(default=None)):
    result = await registry.push_telemetry(_extract_token(authorization), body.kind, body.payload)
    if result is None:
        raise HTTPException(status_code=401, detail="Unknown device token")
    return result
