from __future__ import annotations

import secrets
import time

from app.storage.crypto import encrypt, decrypt, hash_token
from app.storage.db import get_db, new_id, now, dumps, loads, row_to_dict

HEARTBEAT_INTERVAL = 30  # seconds; node apps are expected to check in this often
OFFLINE_AFTER = HEARTBEAT_INTERVAL * 3  # mark offline if no heartbeat for 3 intervals


async def register_device(name: str, platform: str, owner: str) -> dict:
    """Register a new node app. Returns a bearer token the node must send on every
    request -- shown once, here. Only its hash is ever stored server-side."""
    token = secrets.token_urlsafe(24)
    device_id = new_id()
    async with get_db() as db:
        await db.execute(
            "INSERT INTO devices (id, name, platform, owner, token_hash, status, last_seen, created_at) "
            "VALUES (?, ?, ?, ?, ?, 'offline', NULL, ?)",
            (device_id, name, platform, owner, hash_token(token), now()),
        )
        await db.commit()
    return {"device_id": device_id, "token": token}


async def _device_by_token(token: str) -> dict | None:
    async with get_db() as db:
        cur = await db.execute("SELECT * FROM devices WHERE token_hash = ?", (hash_token(token),))
        row = await cur.fetchone()
    return row_to_dict(row) if row else None


async def heartbeat(token: str, battery: float | None = None, lat: float | None = None, lon: float | None = None) -> dict | None:
    """Record a 30s check-in from a node. Battery is cached directly on the devices row
    (not sensitive enough to bother encrypting). Location is NOT cached in plaintext --
    it's written through push_telemetry() below so it gets the same encryption-at-rest
    as every other telemetry kind, rather than living as a bare lat/lon column."""
    device = await _device_by_token(token)
    if not device:
        return None
    async with get_db() as db:
        await db.execute(
            "UPDATE devices SET status = 'online', last_seen = ?, "
            "last_battery = COALESCE(?, last_battery) WHERE id = ?",
            (now(), battery, device["id"]),
        )
        await db.commit()
    if lat is not None and lon is not None:
        await push_telemetry(token, "location", {"lat": lat, "lon": lon})
    return {"device_id": device["id"], "status": "ok"}


async def push_telemetry(token: str, kind: str, payload: dict) -> dict | None:
    """Store an arbitrary telemetry payload from a node: screenshot, notification list,
    location, sensor reading, etc. Payload is encrypted at rest -- this is the path
    screenshots and notification content take, so it's the one that matters most."""
    device = await _device_by_token(token)
    if not device:
        return None
    async with get_db() as db:
        await db.execute(
            "INSERT INTO device_telemetry (id, device_id, kind, payload, created_at) VALUES (?, ?, ?, ?, ?)",
            (new_id(), device["id"], kind, encrypt(dumps(payload)), now()),
        )
        await db.commit()
    return {"status": "ok"}


async def queue_command(device_id: str, kind: str, payload: dict) -> dict:
    """Queue an outgoing command for a device (e.g. a notification to display, or a
    one-off screenshot request). Delivered the next time that device heartbeats.
    Not encrypted: these are commands the server is choosing to send, not data
    collected from the device, so they're lower sensitivity by construction."""
    async with get_db() as db:
        cmd_id = new_id()
        await db.execute(
            "INSERT INTO outgoing_commands (id, device_id, kind, payload, status, created_at) "
            "VALUES (?, ?, ?, ?, 'pending', ?)",
            (cmd_id, device_id, kind, dumps(payload), now()),
        )
        await db.commit()
    return {"command_id": cmd_id}


async def pop_pending_commands(device_id: str) -> list[dict]:
    """Called from the heartbeat response: return and mark-delivered any commands
    queued for this device since its last check-in."""
    async with get_db() as db:
        cur = await db.execute(
            "SELECT id, kind, payload FROM outgoing_commands WHERE device_id = ? AND status = 'pending'",
            (device_id,),
        )
        rows = await cur.fetchall()
        if rows:
            await db.execute(
                "UPDATE outgoing_commands SET status = 'delivered' WHERE device_id = ? AND status = 'pending'",
                (device_id,),
            )
            await db.commit()
    return [{"command_id": r["id"], "kind": r["kind"], "payload": loads(r["payload"])} for r in rows]


async def list_devices() -> list[dict]:
    async with get_db() as db:
        cur = await db.execute("SELECT * FROM devices ORDER BY last_seen DESC")
        rows = await cur.fetchall()
    devices = []
    for r in rows:
        d = row_to_dict(r)
        d.pop("token_hash", None)  # never leak, not even the hash
        if d["last_seen"] and (time.time() - d["last_seen"]) > OFFLINE_AFTER:
            d["status"] = "offline"
        devices.append(d)
    return devices


async def get_device_context(device_id: str, telemetry_limit: int = 10) -> dict | None:
    async with get_db() as db:
        cur = await db.execute("SELECT * FROM devices WHERE id = ?", (device_id,))
        row = await cur.fetchone()
        if not row:
            return None
        device = row_to_dict(row)
        device.pop("token_hash", None)

        cur = await db.execute(
            "SELECT kind, payload, created_at FROM device_telemetry WHERE device_id = ? "
            "ORDER BY created_at DESC LIMIT ?",
            (device_id, telemetry_limit),
        )
        telemetry_rows = await cur.fetchall()

    if device["last_seen"] and (time.time() - device["last_seen"]) > OFFLINE_AFTER:
        device["status"] = "offline"

    device["recent_telemetry"] = [
        {"kind": t["kind"], "payload": loads(decrypt(t["payload"])), "created_at": t["created_at"]}
        for t in telemetry_rows
    ]
    return device
