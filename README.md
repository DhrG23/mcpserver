# Personal AI MCP Server

The shared backend for both hackathon submissions: one MCP server, two AI
callers (Alexa+ and a Nemotron agent on Nebius), plus a device gateway for
your Linux/Android/iOS/macOS node apps.

## Architecture

Two ASGI apps, one process, two ports (kept separate deliberately to avoid
ASGI lifespan-composition issues between FastAPI and the MCP SDK's session
manager):

- **`:8000` — MCP endpoint** (Streamable HTTP, spec 2025-11-25+, path `/mcp`)
  This is what Alexa+ and the Nemotron agent call. 18 tools across memory,
  tasks, calendar, web, files, device context, notifications, automation.
- **`:8001` — Device gateway + approvals** (plain REST)
  This is what node apps call (`/devices/register`, `/devices/heartbeat`,
  `/devices/telemetry`) and what a human uses to review approval-gated tool
  calls (`/approvals`).

Storage is a single SQLite file — fine at personal scale, swap `app/storage/db.py`
for Postgres later if this grows.

## Permissions

Every tool call is checked against a `(caller, tool) -> scope` table in
`app/permissions/scopes.py`:
- **allow** — runs immediately
- **approval** — queued in `pending_approvals`; check/resolve via `GET/POST /approvals`
- **deny** (default for anything unlisted) — rejected with a clear message

Caller identity comes from the `Authorization: Bearer <token>` header, mapped
via `ALEXA_TOKEN` / `NEMOTRON_TOKEN` / `OLLAMA_TOKEN` / `ADMIN_TOKEN` env vars.
Edit the `DEFAULT_SCOPES` dict to change what each caller can do — that one
file is the entire authorization policy.

## Encryption

**In transit:** everything, no exceptions — every request carries a bearer
token, and telemetry can carry screenshots. Always hit the server over
HTTPS (Caddy gives you this for free, whether via a real domain or the
`tls internal` local mode below), never plain HTTP to the container ports
directly.

**At rest**, handled in `app/storage/crypto.py`:
- `memory.value`, `device_telemetry.payload` (screenshots, notifications,
  location, sensor data) — encrypted with a server-held Fernet key from
  `DATA_ENCRYPTION_KEY`.
- `devices.token_hash` — device bearer tokens are stored as a SHA-256 hash,
  never in plaintext; a DB leak can't be used to impersonate a device.
- Task/calendar titles, automation rules, battery level — left as plaintext;
  judged low-sensitivity enough not to be worth the complexity.

Be accurate about what this buys you: it's encryption with a **server-held
key**, not end-to-end. Alexa+/Nemotron/Ollama all need to read this data to
be useful, so the running server can always decrypt it. What it protects
against is someone getting the SQLite file or a backup without the key —
not a compromised running server. That's the honest bar for a personal-scale
project, not full privacy.

Generate a real key before running for real:
```bash
python3 -c "from cryptography.fernet import Fernet; print(Fernet.generate_key().decode())"
```
Put it in `.env` as `DATA_ENCRYPTION_KEY`. If it's unset, the server
generates a throwaway one each restart and prints a loud warning — fine for
a five-minute test, wrong for anything you expect to still read later.

## Quickstart (local dev)

```bash
python3 -m venv .venv && source .venv/bin/activate
pip install fastapi "uvicorn[standard]" "mcp>=2.0" pydantic aiosqlite httpx python-multipart

cp .env.example .env   # defaults to DuckDuckGo for search_web, no key needed;
                        # set SEARCH_PROVIDER=tavily + TAVILY_API_KEY for the Nebius build
set -a; source .env; set +a

python3 -m app.main
# MCP:     http://localhost:8000/mcp
# Gateway: http://localhost:8001
```

Sanity check:
```bash
curl http://localhost:8001/healthz
curl -X POST http://localhost:8001/devices/register \
  -H "Content-Type: application/json" \
  -d '{"name":"arch-desktop","platform":"linux","owner":"you"}'
```

## Docker (VPS deployment)

```bash
cd docker
cp ../.env.example ../.env   # edit with real tokens + DATA_ENCRYPTION_KEY
# Edit Caddyfile: replace your-domain.example.com with your real domain
docker compose up -d --build
```

Caddy handles TLS automatically for a real domain. For quick local testing
without a domain, hit the container ports directly instead of going through
Caddy.

## Running locally on your LAN (with Ollama)

Same server, no public domain needed — useful for a fully-local personal
instance with an Ollama-based agent as the caller instead of Nemotron.

```bash
cd docker
cp ../.env.example ../.env   # set DATA_ENCRYPTION_KEY and OLLAMA_TOKEN for real
docker compose -f docker-compose.yml -f docker-compose.local.yml up -d --build
```

This uses `Caddyfile.local`, which issues a self-signed cert via Caddy's
`tls internal` instead of a public one, so heartbeats/telemetry are still
HTTPS — bearer tokens aren't sent in cleartext over the LAN. Your node apps
and dev machine need to trust Caddy's local root CA once; see the setup
notes at the top of `docker/Caddyfile.local` (Linux, Android, iOS/macOS
each need slightly different steps).

Point your Ollama-based agent loop at `https://<lan-ip>:8443/mcp` with
`Authorization: Bearer <OLLAMA_TOKEN>`.

At-rest encryption (memory, telemetry, device tokens) applies identically
in this mode — it protects the SQLite file regardless of how requests
reached the server, so switching to LAN-only doesn't quietly weaken it.

## Calling the MCP endpoint

Any MCP client works as long as it speaks Streamable HTTP and sends the
bearer token. Minimal Python example (used to verify this server):

```python
import httpx
from mcp import ClientSession
from mcp.client.streamable_http import streamable_http_client

async def call(tool, args, token):
    headers = {"Authorization": f"Bearer {token}"}
    async with httpx.AsyncClient(headers=headers) as hc:
        async with streamable_http_client("https://your-domain/mcp", http_client=hc) as (r, w):
            async with ClientSession(r, w) as session:
                await session.initialize()
                result = await session.call_tool(tool, args)
                return result.structured_content
```

## Node apps (device gateway contract)

Node apps don't speak MCP — they speak this plain REST contract:

1. **Register once**, store the returned token securely on-device:
   `POST /devices/register {"name", "platform", "owner"}` → `{"device_id", "token"}`
2. **Heartbeat every 30s**:
   `POST /devices/heartbeat` (Bearer token) `{"battery", "lat", "lon"}` →
   returns `pending_commands` (e.g. queued notifications) to act on immediately.
3. **Push heavier/less frequent data**:
   `POST /devices/telemetry` (Bearer token) `{"kind": "screenshot", "payload": {"data_b64": "..."}}`

The MCP tools `list_devices()` and `get_device_context(device_id)` read this
same data back out for Alexa+/Nemotron to use.

## Known next steps (not built yet, flagged in code)

- **Automation execution**: `create_automation` stores trigger→action rules
  but nothing currently watches triggers and fires them. Needs a scheduler
  loop (e.g. APScheduler) that polls `automations`, evaluates triggers, and
  invokes the target tool.
- **Approval replay**: approving a queued call marks it resolved but doesn't
  automatically re-run the original tool with its stored args. Needs the
  `/approvals/{id}/decide` handler to actually invoke `mcp_server.call_tool(...)`
  on approval.
- **Two-port → one-port**: fine behind Caddy path-routing as-is; only worth
  merging into a single ASGI app if you hit a deployment environment that
  won't let you expose two ports.

## Repo layout

```
app/
  main.py              entrypoint - runs both ASGI apps
  mcp_tools/           one file per tool domain (memory, tasks, calendar, web, files, device, notify, automation)
  storage/db.py         SQLite schema + connection helper
  permissions/scopes.py caller resolution + scope table + guarded() decorator
  permissions/admin.py   /approvals endpoints
  devices/registry.py    device register/heartbeat/telemetry/command-queue logic
  devices/gateway.py      /devices/* REST routes
docker/                 Dockerfile, docker-compose.yml, Caddyfile
.env.example
```
