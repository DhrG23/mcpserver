#!/usr/bin/env bash
# restart.sh -- restart the server WITHOUT deleting anything (data, accounts, .env, venv all stay).
#
#   ./restart.sh                 # auto-detects docker or local mode and restarts it
#   ./restart.sh --rebuild       # docker: rebuild the image first (use after changing code)
#   ./restart.sh --mode local    # force a mode (docker | local)
#   ./restart.sh --logs          # follow the logs afterwards (Ctrl-C leaves them; server keeps running)
#
# Use ./reset_and_start.sh instead if you want to wipe everything and start from zero.

set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"

MODE=""; REBUILD=0; LOGS=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --mode) MODE="${2:-}"; shift 2 ;;
    --rebuild) REBUILD=1; shift ;;
    --logs) LOGS=1; shift ;;
    -h|--help) sed -n '2,9p' "$0"; exit 0 ;;
    *) echo "Unknown option: $1 (try --help)"; exit 2 ;;
  esac
done

if [[ -t 1 ]]; then B=$'\033[1m'; G=$'\033[32m'; Y=$'\033[33m'; R=$'\033[31m'; N=$'\033[0m'; else B=""; G=""; Y=""; R=""; N=""; fi
step() { echo; echo "${B}==> $*${N}"; }
ok()   { echo "${G}ok${N}  $*"; }
die()  { echo "${R}error${N} $*" >&2; exit 1; }

[[ -f app/main.py && -f .env ]] || die "Run from the mcpserver-main folder, and create .env first (./reset_and_start.sh does this)."

# Make sure there is an invite code (older .env files don't have one) and remember it for the summary.
python3 scripts/invite_code.py --ensure --quiet || true
INVITE_VAL="$(grep -E '^INVITE_CODE=' .env | head -1 | cut -d= -f2- | sed 's/[[:space:]#].*//')"

local_running() { [[ -f data/server.pid ]] && kill -0 "$(cat data/server.pid)" 2>/dev/null; }
docker_ready()  { docker info >/dev/null 2>&1; }

# ---- pick the mode
if [[ -z "$MODE" ]]; then
  if local_running; then MODE="local"
  elif [[ -d .venv && ! -x "$(command -v docker || true)" ]]; then MODE="local"
  else MODE="docker"; fi
fi
[[ "$MODE" == "docker" || "$MODE" == "local" ]] || die "--mode must be docker or local"
echo "Mode: $MODE"

SERVER_HOST_VAL="$(grep -E '^SERVER_HOST=' .env | head -1 | cut -d= -f2- | sed 's/[[:space:]#].*//')"
[[ -n "$SERVER_HOST_VAL" ]] || SERVER_HOST_VAL="127.0.0.1"

# If SERVER_HOST is an IPv4 address that is no longer this Mac's address (new Wi-Fi, DHCP change, or a
# placeholder from the docs), Caddy would issue a certificate for the wrong address and nothing connects.
CURRENT_IP="$(ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1 2>/dev/null || true)"
if [[ "$MODE" == "docker" && -n "$CURRENT_IP" && "$SERVER_HOST_VAL" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ && "$SERVER_HOST_VAL" != "$CURRENT_IP" ]]; then
  echo "${Y}warn${N} SERVER_HOST=$SERVER_HOST_VAL but this Mac is $CURRENT_IP - updating .env."
  echo "     (The app's server address becomes https://$CURRENT_IP:8443. Give the Mac a fixed IP in your router to stop this.)"
  perl -pi -e "s/^SERVER_HOST=.*/SERVER_HOST=$CURRENT_IP/" .env
  SERVER_HOST_VAL="$CURRENT_IP"
fi
COMPOSE=(docker compose -p personal-ai --env-file ../.env -f docker-compose.yml -f docker-compose.local.yml)

if [[ "$MODE" == "docker" ]]; then
  step "Docker"
  command -v docker >/dev/null 2>&1 || die "Docker is not installed (brew install --cask docker)."
  if ! docker_ready; then
    echo "Docker isn't running - starting Docker Desktop..."
    open -a Docker || die "Could not open Docker Desktop. Start it manually and re-run."
    for _ in $(seq 1 60); do docker_ready && break; sleep 3; printf "."; done; echo
    docker_ready || die "Docker did not become ready in 3 minutes."
  fi
  ok "Docker engine is running"

  step "Restarting containers"
  if [[ $REBUILD -eq 1 ]]; then
    (cd docker && "${COMPOSE[@]}" up -d --build)
  else
    # 'up -d' (re)creates what is missing and picks up .env changes; 'restart' alone would not.
    (cd docker && "${COMPOSE[@]}" up -d --force-recreate)
  fi
  URL="https://$SERVER_HOST_VAL:8443"; HEALTH=(curl -ksS --max-time 3 "$URL/healthz")
else
  step "Restarting local server"
  [[ -x .venv/bin/python ]] || die ".venv not found. Run ./reset_and_start.sh --mode local first."
  if local_running; then
    kill "$(cat data/server.pid)" 2>/dev/null || true
    for _ in $(seq 1 10); do local_running || break; sleep 1; done
    local_running && kill -9 "$(cat data/server.pid)" 2>/dev/null || true
    ok "old process stopped"
  fi
  mkdir -p data
  nohup .venv/bin/python -m app.main >> data/server.log 2>&1 &
  echo $! > data/server.pid
  URL="http://127.0.0.1:8001"; HEALTH=(curl -sS --max-time 3 "$URL/healthz")
fi

step "Waiting for the server to answer"
ERRF="$(mktemp)"; UP=0
for _ in $(seq 1 40); do
  if out="$("${HEALTH[@]}" 2>"$ERRF")" && [[ "$out" == *'"ok"'* ]]; then ok "server is up: $out"; UP=1; break; fi
  sleep 3; printf "."
done; echo
if [[ $UP -ne 1 ]]; then
  echo "Last curl error: $(tail -1 "$ERRF")"
  echo "Last logs:"
  if [[ "$MODE" == "docker" ]]; then
    (cd docker && "${COMPOSE[@]}" logs --tail 40 personal-ai-mcp caddy) || true
    echo; echo "${B}Diagnosis${N}"
    if (cd docker && "${COMPOSE[@]}" exec -T personal-ai-mcp python -c "import urllib.request;urllib.request.urlopen('http://127.0.0.1:8001/healthz',timeout=3)") >/dev/null 2>&1; then
      echo "  Python server: OK.  The problem is the HTTPS address $URL (Caddy / network)."
      echo "  Check SERVER_HOST in .env matches: ipconfig getifaddr en0   (now: ${CURRENT_IP:-unknown})"
    else
      echo "  Python server: NOT answering - see the traceback in the logs above."
    fi
  else tail -40 data/server.log || true; fi
  die "The server did not become healthy."
fi

echo; echo "${G}${B}Restarted.${N}  Server address: ${B}$URL${N}"
[[ -n "${INVITE_VAL:-}" ]] && echo "                Invite code (Node app -> register):  ${B}$INVITE_VAL${N}"
if [[ $LOGS -eq 1 ]]; then
  if [[ "$MODE" == "docker" ]]; then (cd docker && "${COMPOSE[@]}" logs -f personal-ai-mcp)
  else tail -f data/server.log; fi
fi
