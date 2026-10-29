# SETUP — start the whole project

This guide takes you from a fresh checkout to **the Node app chatting with your own server**.
Follow the sections in order; each ends with a check so you know it worked.

> **Read this first — what has and hasn't been tested.**
> The code in this repo was written in a sandbox with no network, so the server was **compiled and
> unit-checked (password hashing, rate limiter, encryption + key rotation) but never started**.
> The integration tests in `tests/` and the checks in §8 are how you confirm it on your machine.
> Run them before trusting anything. Anything that depends on guesses is listed in §13.

---

## 0. What you are starting

```
 Node app (iOS/macOS)                       Your server (this repo)
 ───────────────────                        ──────────────────────────────────────────────
  Chat tab   ──wss──►                       Caddy :8443 (TLS)
  Devices    ──https─►                        ├─ /chat/ws /auth/* /heartbeat /devices* /approvals*
  Account    ──https─►                        │      └─► gateway app   :8001  (FastAPI)
                                              └─ /mcp
 Alexa+ / Nemotron / Ollama agent ──https─►          └─► MCP app       :8000  (Streamable HTTP)

                                            one Python process · one SQLite file · encrypted at rest
                                            chat model: Ollama (local) · OpenAI-compatible (e.g. Nebius) · echo (test)
```

Three things must be true for the app to work:

1. The server is running (§3).
2. It is reachable over **HTTPS** — the app refuses `http://` (§4).
3. You have an account on it (§5).

Everything else (a real model, Ollama agent, Alexa) is optional.

---

## 1. Prerequisites

| Need | Version | Notes |
|---|---|---|
| Python | 3.11 or newer | `python3 --version` |
| One way to do HTTPS | — | Docker **or** Caddy on the host **or** a public domain (§4) |
| `curl` | any | for checks |
| `websocat` | any | optional, for testing the chat socket (`brew install websocat`) |
| Ollama | any | only if you want a local chat model (§6) |
| Xcode | the version your project targets | for the Node app (§7) |

---

## 2. Get the code and create `.env`

```bash
cd mcpserver-main
python3 -m venv .venv
source .venv/bin/activate              # Windows: .venv\Scripts\activate
pip install -r requirements.txt
python3 scripts/gen_env.py             # creates .env with fresh random secrets
```

`gen_env.py` fills in the four caller tokens and `DATA_ENCRYPTION_KEY`. It refuses to overwrite an
existing `.env`. Flags: `--host 192.168.1.20` (Docker LAN mode), `--domain node.example.com` (Docker public mode).

**Back up `DATA_ENCRYPTION_KEY`.** Without it, memory, device snapshots and chat history in the database
cannot be read again.

Open `.env` and check these now:

| Setting | Set it to |
|---|---|
| `CHAT_LLM_PROVIDER` | `echo` for the first run (no model needed). Change later in §6. |
| `CHAT_AGENT_CALLER` | `ollama` if you'll use Ollama, `nemotron` if you'll use a hosted model. |
| `INVITE_CODE` | created for you by `gen_env.py`; this is what the app's register screen asks for (§5). |
| `ALLOW_REGISTRATION` | leave `false`; only used when `INVITE_CODE` is empty. |

**Check:** `grep -c "=" .env` prints a number > 20, and `grep DATA_ENCRYPTION_KEY .env` shows a long value.

---

## 3. Run the server

```bash
source .venv/bin/activate
python3 -m app.main
```

You should see two uvicorn lines: one on `127.0.0.1:8000` (MCP) and one on `127.0.0.1:8001` (gateway).
The database is created at `./data/personal_ai.db` on first use.

**Check** (second terminal):

```bash
curl -s http://127.0.0.1:8001/healthz
# {"status":"ok"}
```

The server binds to `127.0.0.1` on purpose: nothing outside this machine can reach it until you put
Caddy (TLS) in front. Don't change `BIND_HOST` to `0.0.0.0` outside Docker.

> If startup fails with `ImportError ... mcp.server.mcpserver`, your installed `mcp` package doesn't match the
> version this repo was written for. Run `pip install -U "mcp>=2.0"`, or see §12.

---

## 4. Add HTTPS (required by the app)

The app only talks to `https://` / `wss://`. Pick **one** option.

### Option A — Docker on your home network (recommended for personal use)

Needs Docker with Compose ≥ 2.24.4 (`docker compose version`).

```bash
python3 scripts/gen_env.py --host 192.168.1.20      # skip if .env exists: just set SERVER_HOST=... in it
cd docker
docker compose --env-file ../.env -f docker-compose.yml -f docker-compose.local.yml up -d --build
docker compose --env-file ../.env logs -f personal-ai-mcp        # Ctrl-C to leave the logs
```

`SERVER_HOST` must be the LAN IP or hostname your phone will type. Give the machine a fixed IP in your router
(DHCP reservation), otherwise the address changes and the certificate stops matching.

Your **server address** is `https://192.168.1.20:8443` (use your own value).

### Option B — Caddy on the host, no Docker

```bash
brew install caddy                                   # or your package manager
python3 -m app.main &                                # §3, still running
SERVER_HOST=192.168.1.20 caddy run --config docker/Caddyfile.host
```

Caddy may ask for your password once to trust its local certificate authority on this machine. That is only needed
for tools on this machine; the Node app does not use it (§7).

### Option C — public domain on a VPS

Point a DNS `A` record at the VPS, open ports 80 and 443, then:

```bash
python3 scripts/gen_env.py --domain node.example.com
cd docker
docker compose --env-file ../.env up -d --build
```

Caddy gets and renews a real certificate automatically. Server address: `https://node.example.com`.

### Check (all options)

```bash
curl -k https://192.168.1.20:8443/healthz           # -k = accept the self-signed certificate (A and B only)
# {"status":"ok"}
```

Why the app doesn't need a CA installed: at sign-in it shows the server certificate's SHA-256 fingerprint and you
tap **Trust this server**; it then pins that fingerprint (see `ServerTrust` in the app).

---

## 5. Create your account

The Node app's register screen asks for an **invite code**. It is the `INVITE_CODE` line in your `.env`.

```bash
python3 scripts/invite_code.py            # prints the code (creates one if .env has none)
python3 scripts/invite_code.py --new      # replace it with a fresh code
./restart.sh                              # restart so the server picks it up
```

`./reset_and_start.sh` and `./restart.sh` also print the code when they finish. Anyone who has the code can
create an account (even after the first one), so keep it private; 10 wrong guesses lock the guesser's IP out for
15 minutes. If `INVITE_CODE` is empty, the old rule applies: the first account is always allowed and later ones need
`ALLOW_REGISTRATION=true`.

Easiest: in the Node app, sign-in screen -> register with email, password and the invite code (§7). Or from a terminal:

```bash
curl -ks -X POST https://192.168.1.20:8443/auth/register \
  -H 'Content-Type: application/json' \
  -d '{"email":"you@example.com","password":"a-long-password","name":"Veerjyot","invite_code":"NODE-XXXXX-XXXXX"}'
# {"token":"...","user_name":"Veerjyot"}
```

Keep the token in a shell variable for the checks below: `T=<the token>`.

* Wrong or missing code -> **403 "Invalid invite code."**; too many wrong guesses -> **429**.
* Passwords need >= 8 characters (`MIN_PASSWORD_LEN`). 5 wrong logins in 15 minutes returns **429**.
* Tokens last 30 days (`TOKEN_TTL_DAYS`).

---

## 6. Choose the chat "brain"

Chat answers come from `CHAT_LLM_PROVIDER`. Restart the server after changing `.env`.

### `echo` — no model (first run, and for testing)

Repeats what you say. Typing a message containing **"location"** triggers the approval-gated `get_location` tool, and
one containing **"device"** calls `list_devices` — handy for seeing streaming, cancel and approval chips without a model.
Never leave this on for real use.

### `ollama` — local model

```bash
ollama pull qwen3.5:2b
ollama serve                                          # if it isn't already running
```
```dotenv
CHAT_LLM_PROVIDER=ollama
CHAT_LLM_MODEL=qwen3.5:2b
CHAT_AGENT_CALLER=ollama
# CHAT_LLM_BASE_URL=http://127.0.0.1:11434            # default
```
Pick a model that supports **tool calling**; a model that doesn't will answer in text but never use your tools.
If the server runs in Docker and Ollama on the host, set `CHAT_LLM_BASE_URL=http://host.docker.internal:11434`
(on Linux add `extra_hosts: ["host.docker.internal:host-gateway"]` to the service).

### `openai` — any OpenAI-compatible API (e.g. Nemotron on Nebius)

```dotenv
CHAT_LLM_PROVIDER=openai
CHAT_LLM_BASE_URL=<the provider's /v1 base URL>
CHAT_LLM_API_KEY=<your key>
CHAT_LLM_MODEL=<model id from the provider's catalogue>
CHAT_AGENT_CALLER=nemotron
```
Look up the current base URL and model id in the provider's documentation; they change.

**Which caller identity?** Chat runs as `CHAT_AGENT_CALLER` and gets exactly that caller's rows in
`app/permissions/scopes.py` — nothing more. Out of the box `get_location`, `send_notification`, `forget` and
`create_automation` need your approval for every caller.

**Check:** with the server running, §8 step 3 (WebSocket) should return an answer.

---

## 7. Connect the Node app

1. Open the project in Xcode and **build once**. `CLAUDE.md` §7.4 warns the chat code was never compiled; fix any
   concurrency warnings first.
2. **Re-enable the login gate** in `MainView.body` (`CLAUDE.md` §7.1) — currently commented out.
3. **Real iPhone on your LAN:** add `NSLocalNetworkUsageDescription` (Build Settings →
   `INFOPLIST_KEY_NSLocalNetworkUsageDescription`) or iOS may block `https://192.168.x.x:8443` silently (`CLAUDE.md` §7.5).
4. Run the app. On the sign-in screen enter the **server address** from §4.
5. The app shows a certificate fingerprint. Compare it with the server's, then tap **Trust this server**:
   ```bash
   openssl s_client -connect 192.168.1.20:8443 </dev/null 2>/dev/null | openssl x509 -noout -fingerprint -sha256
   ```
6. Sign in / register, set a PIN.
7. **Devices** tab → **Sync now** sends a snapshot. It appears under Devices and in `GET /devices`.
8. **Chat** tab → send a message. You should see the typing dots, then the streamed answer.

If the app says "session rejected" right after sign-in, the token was refused — check the server log and §12.

---

## 8. Verify everything (do this once)

Use `T` from §5 and your server address as `H`:

```bash
H=https://192.168.1.20:8443        # or http://127.0.0.1:8001 when testing without Caddy
```

**1. Auth and error shape**
```bash
curl -ks -X POST $H/auth/login -H 'Content-Type: application/json' -d '{"email":"you@example.com","password":"wrong"}'
# {"detail":"Incorrect name or password."}      (HTTP 401)
curl -ks $H/auth/me -H "Authorization: Bearer $T"
```

**2. Heartbeat and device list**
```bash
curl -ks -X POST $H/heartbeat -H "Authorization: Bearer $T" -H 'Content-Type: application/json' \
  -d '{"schema_version":4,"device_id":"test-1","device_name":"Test phone","platform":"ios","battery":{"level":80}}'
curl -ks $H/devices -H "Authorization: Bearer $T"
```

**3. Chat socket** (`websocat -k` accepts a self-signed certificate)
```bash
websocat -k -H="Authorization: Bearer $T" ${H/https/wss}/chat/ws
```
You should immediately see a `ready` frame. Then paste lines:

| Paste | Expect |
|---|---|
| `{"type":"history.get","limit":50}` | one `history` frame |
| `{"type":"chat.send","client_id":"t1","text":"hello","sent_at":"2026-10-04T10:00:00Z"}` | `chat.ack` → `assistant.start` → `assistant.delta`… → `assistant.end` |
| the same line again | `chat.ack` only, no second answer |
| `{"type":"nope"}` | `error` / `invalid_frame`, socket stays open |
| `{"type":"chat.send","client_id":"t2","text":"share my location"}` (echo provider) | `tool.status` with `approval_required`; no coordinates anywhere |

Without a token (`websocat -k wss://…/chat/ws`) the upgrade must be refused with HTTP 401/403.

**4. Approvals** (the gated call from step 3)
```bash
curl -ks $H/approvals -H "Authorization: Bearer $T"                         # note the "id"
curl -ks -X POST $H/approvals/<id>/decide -H "Authorization: Bearer $T" \
  -H 'Content-Type: application/json' -d '{"approve":true}'
```
Approving re-runs the stored call and updates the chat chip to `done` / `failed`. The result is stored encrypted and
readable only via `GET /approvals/<id>`; it is never put into a chat answer.

**5. Logout closes sockets:** `curl -ks -X POST $H/auth/logout -H "Authorization: Bearer $T"` while websocat is
connected → the socket closes with code 4401.

**6. Encrypted at rest**
```bash
sqlite3 data/personal_ai.db "select substr(text,1,24) from chat_messages limit 3;"     # starts with gAAAAA…
```

**7. No message text in logs:** `docker compose logs personal-ai-mcp | grep -i hello` finds nothing.

---

## 9. Optional: other MCP callers

* **Ollama agent (CLI):** `agent/README.md`. Set `OLLAMA_TOKEN` in `agent/agent.env` to the same value as in `.env`,
  `MCP_URL=https://<host>:8443/mcp`, then `python -m agent.main --check`.
* **Alexa+ / hosted agents:** send `Authorization: Bearer <ALEXA_TOKEN or NEMOTRON_TOKEN>` to `https://<host>/mcp`.
* **Approval flow for these callers:** gated tools return `{"status":"approval_required","approval_id":…}`; decide
  with `/approvals` (§8.4).

---

## 10. Run the automated tests

```bash
pip install -r requirements-dev.txt
pytest -q
```

They start the gateway in-process with the `echo` model and a temporary database, and cover: register/login/logout,
throttling, user-scoped devices, error shape, and the chat acceptance cases (ack/stream/idempotency/too-long/cancel/
invalid frame/approval gate/cross-user isolation/logout → 4401). Nothing touches your real database.

If a test fails on your machine, that is useful information — fix the code or tell me what you see.

---

## 11. Day-to-day operations

| Task | How |
|---|---|
| Stop / start (Docker) | `cd docker && docker compose --env-file ../.env down` / `up -d` |
| Update | pull code, `docker compose … up -d --build`; the database migrates itself on start |
| Back up | copy `data/personal_ai.db*` **and** your `DATA_ENCRYPTION_KEY`. Docker: `docker run --rm -v docker_personal_ai_data:/data -v $PWD:/out alpine tar czf /out/backup.tgz /data` (volume name may differ: `docker volume ls`) |
| Rotate the encryption key | generate a new key; put it in `DATA_ENCRYPTION_KEY`, move the old one to `DATA_ENCRYPTION_KEY_OLD`; restart. Old rows stay readable, new rows use the new key. Old rows are not re-encrypted automatically. |
| Change what the assistant may do | edit `DEFAULT_SCOPES` in `app/permissions/scopes.py`. New rows are added on start, but **existing database rows win** — to change an existing rule: `sqlite3 data/personal_ai.db "update permissions set scope='approval' where caller='ollama' and tool='create_task';"` |
| Audit trail | `sqlite3 data/personal_ai.db "select datetime(ts,'unixepoch'),caller,tool,decision from audit_log order by ts desc limit 20;"` (argument values are never stored) |
| Delete chat history | app-side not built yet; `curl -X DELETE $H/chat/conversations/conv_<user_id> -H "Authorization: Bearer $T"`. Everything for a user: `DELETE $H/account/data` |
| Retention | chat older than `CHAT_HISTORY_RETENTION_DAYS` (90) is deleted daily |
| Reset everything | stop the server, delete `data/` (or `docker volume rm …`). This destroys all data. |

---

## 12. Troubleshooting

| Symptom | Likely cause → fix |
|---|---|
| App: "can't connect" / spinner | Phone and server on different networks; wrong IP; firewall blocking 8443. Test `curl -k https://<ip>:8443/healthz` from another device. |
| App: untrusted certificate prompt every time | `SERVER_HOST` doesn't match the address typed in the app. Use the same IP/hostname in both. |
| iPhone never asks for local-network permission | Missing `NSLocalNetworkUsageDescription` (§7.3). |
| Chat: "session rejected" | Token expired/revoked (log in again) or the gateway wasn't reached (check Caddy routes include `/chat/*`). |
| Chat connects, replies "agent unavailable" | Model backend unreachable: Ollama not running, wrong `CHAT_LLM_BASE_URL`, bad API key. Check server logs (they show the error class, never message text). |
| Replies appear but tools never run | The model doesn't support tool calling, or `CHAT_AGENT_CALLER` has no `allow` rows (see §11 audit trail). |
| `ImportError: mcp.server.mcpserver` | Installed `mcp` SDK differs from the one this repo targets; upgrade (`pip install -U "mcp>=2.0"`) or adjust imports in `app/mcp_tools/*.py`. |
| Docker: Caddy can't reach the app | `.env` has `BIND_HOST=127.0.0.1` — compose overrides it to `0.0.0.0`; make sure you use the compose files in `docker/` unchanged. |
| `ports: !override` error | Docker Compose older than 2.24.4. Upgrade, or use Option B. |
| curl: `tlsv1 alert internal error` when using the IP | Caddy needs `default_sni` (already in Caddyfile.local). Recreate with `./restart.sh`. |
| Everything says "Could not decrypt" | `DATA_ENCRYPTION_KEY` changed. Restore the old key (put it in `DATA_ENCRYPTION_KEY_OLD`). |
| Many 429 on login | You hit the brute-force limit; wait 15 minutes. |
| `fetch_webpage` refuses a LAN address | Intentional (SSRF guard). `ALLOW_PRIVATE_FETCH=true` disables it. |

---

## 13. What was built, and what to double-check

**Added for `CLAUDE.md` / `server.md`:** accounts and tokens (`/auth/*`), the app's `/heartbeat` and the Devices API
(`GET /devices`, `GET|PATCH|DELETE /devices/{id}`, `POST /devices/{id}/commands`), the chat WebSocket `/chat/ws` with
streaming, cancel, idempotency, history, fan-out, rate limits, backpressure and 4401 on logout, `DELETE
/chat/conversations/{id}`, `DELETE /account/data`, encrypted chat storage with retention, an audit log, approval replay,
`get_location` (gated), stale/`captured_at` flags on device context, three model backends, Docker/Caddy routes for all
of it.

**Security fixes made to the existing code** (you didn't ask, but they were open holes once the server is reachable):
`/approvals` and `GET /devices` were unauthenticated; `/devices/register` let anyone create devices;
`fetch_webpage` could reach internal addresses; the files-root check was a string-prefix test; caller tokens were
compared with `==`; the gateway bound to all interfaces by default.

**Assumptions you must check against the app** (the app's `RemoteAuthService`, `DevicesAPI` and `DeviceSnapshot`
source and `NODE_SERVER_CONTEXT.md` were not available to me):

1. **Login/register request keys** — I accept `email` *or* `username`, plus `password` (and `name` on register). Edit
   `Credentials` in `app/auth/routes.py` if the app sends other keys.
2. **Device identity in a snapshot** — read from `device_id` / `device.id`, name from `device_name` / `device.name`,
   platform from `platform`, battery from `battery.level`; otherwise one "primary" device per platform. Edit
   `registry.upsert_app_device` to match `DeviceSnapshot` v4 (the app can also send an `X-Device-Id` header).
3. **Device JSON shape** returned by `GET /devices` is `id, name, platform, status, last_seen, last_battery, created_at`;
   adjust to `RemoteDevice`.
4. **Consent (`sources.enabled`)** is enforced by the app (it omits disabled sources); the server stores what it is
   sent and never asks for more. If `NODE_SERVER_CONTEXT.md` defines a server-side `sources.enabled` field, add that
   filter in `registry.get_device_context`.
5. **Empty chat text** returns `invalid_frame` (the spec's wording is ambiguous); too-long returns `message_too_long`.
6. A frame type `message.created` is sent to a user's *other* sockets so they see messages typed on one device. The app
   ignores unknown frame types, so this is safe.
7. **MCP tools are not per-user.** Memory, tasks, calendar and files are one shared pool for the whole server, as in
   the original design. Accounts isolate chat, devices and approvals, not those tools. Keep `ALLOW_REGISTRATION=false`
   unless you trust everyone who gets an account.
8. **Not built:** automation scheduler (rules are stored but never fired), automatic heartbeat commands handler in the
   app, chat pagination in the app, APNs push, multiple conversations.

Per the working agreements in `CLAUDE.md` §8, if any of these change the wire contract, update `server.md` and the
§6 table in `CLAUDE.md` in the same change.
