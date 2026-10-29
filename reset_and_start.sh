#!/usr/bin/env bash
# reset_and_start.sh -- wipe this project's Python + Docker leftovers, then start it fresh (macOS).
#
#   ./reset_and_start.sh                 # Docker mode (HTTPS on your LAN, what the Node app needs)
#   ./reset_and_start.sh --mode local    # plain Python on 127.0.0.1 (no HTTPS; for quick checks)
#   ./reset_and_start.sh --yes           # skip the confirmation prompt
#   ./reset_and_start.sh --reset-env     # ALSO delete .env (new secrets AND a new encryption key)
#   ./reset_and_start.sh --skip-tests    # don't run pytest before starting
#   ./reset_and_start.sh --host 192.168.1.20   # LAN IP the phone will use (auto-detected otherwise)
#
# It only touches THIS project: its .venv, caches, ./data, and Docker containers/volumes/images that
# belong to this project's compose files. It never runs "docker system prune" and never touches other
# projects, other containers, or your system Python.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"

MODE="docker"; ASSUME_YES=0; RESET_ENV=0; SKIP_TESTS=0; HOST_IP=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --mode) MODE="${2:-}"; shift 2 ;;
    --yes|-y) ASSUME_YES=1; shift ;;
    --reset-env) RESET_ENV=1; shift ;;
    --skip-tests) SKIP_TESTS=1; shift ;;
    --host) HOST_IP="${2:-}"; shift 2 ;;
    -h|--help) sed -n '2,15p' "$0"; exit 0 ;;
    *) echo "Unknown option: $1 (try --help)"; exit 2 ;;
  esac
done
[[ "$MODE" == "docker" || "$MODE" == "local" ]] || { echo "--mode must be docker or local"; exit 2; }

if [[ -t 1 ]]; then B=$'\033[1m'; G=$'\033[32m'; Y=$'\033[33m'; R=$'\033[31m'; N=$'\033[0m'; else B=""; G=""; Y=""; R=""; N=""; fi
step() { echo; echo "${B}==> $*${N}"; }
ok()   { echo "${G}ok${N}  $*"; }
warn() { echo "${Y}warn${N} $*"; }
die()  { echo "${R}error${N} $*" >&2; exit 1; }

[[ "$(uname -s)" == "Darwin" ]] || die "This script is written for macOS. On Linux, follow SETUP.md."
[[ -f app/main.py && -d docker ]] || die "Run this from the mcpserver-main folder (app/main.py not found)."

COMPOSE_PROJECTS=("personal-ai" "docker")   # new name + the default name older runs used
compose_files=(-f docker/docker-compose.yml -f docker/docker-compose.local.yml)

# ---------------------------------------------------------------- confirm
step "This will DELETE (for this project only)"
cat <<EOF
  - Python:  .venv, .venv-agent, __pycache__, .pytest_cache
  - Data:    ./data  (local SQLite database: accounts, chat history, devices, memory)
  - Docker:  this project's containers, networks, images AND volumes (the server's database volume + Caddy certs)
  - .env:    $([[ $RESET_ENV -eq 1 ]] && echo "DELETED and regenerated (new tokens + new encryption key)" || echo "kept (your tokens and encryption key survive)")
Then it will rebuild everything and start the server in '$MODE' mode.
EOF
if [[ $ASSUME_YES -ne 1 ]]; then
  read -r -p "Type 'yes' to continue: " answer
  [[ "$answer" == "yes" ]] || { echo "Cancelled. Nothing was changed."; exit 0; }
fi

# ---------------------------------------------------------------- Homebrew + Python 3.12
step "Python 3.12"
command -v brew >/dev/null 2>&1 || die "Homebrew is not installed. Install it from https://brew.sh, then re-run this script."
if ! brew list python@3.12 >/dev/null 2>&1; then
  echo "Installing python@3.12 with Homebrew (system Python 3.9 is too old)..."
  brew install python@3.12
fi
PY="$(brew --prefix python@3.12)/bin/python3.12"
[[ -x "$PY" ]] || die "Could not find $PY after install."
ok "$("$PY" --version) at $PY"

# ---------------------------------------------------------------- Docker (needed for docker mode)
docker_ready() { docker info >/dev/null 2>&1; }
if [[ "$MODE" == "docker" ]]; then
  step "Docker"
  command -v docker >/dev/null 2>&1 || die "Docker is not installed. Run: brew install --cask docker   (then re-run)"
  if ! docker_ready; then
    echo "Docker isn't running - starting Docker Desktop..."
    open -a Docker || die "Could not open Docker Desktop. Start it manually and re-run."
    for i in $(seq 1 60); do docker_ready && break; sleep 3; printf "."; done; echo
    docker_ready || die "Docker did not become ready within 3 minutes. Open Docker Desktop, wait for 'Engine running', re-run."
  fi
  ok "Docker engine is running"
  have="$(docker compose version --short 2>/dev/null || echo 0)"; need="2.24.4"
  [[ "$(printf '%s\n%s\n' "$need" "${have#v}" | sort -V | head -1)" == "$need" ]] \
    || die "Docker Compose $have is older than $need (needed for 'ports: !override'). Update Docker Desktop."
fi

# ---------------------------------------------------------------- tear down old state
step "Stopping and removing old state"
if [[ -f data/server.pid ]] && kill -0 "$(cat data/server.pid)" 2>/dev/null; then
  kill "$(cat data/server.pid)" 2>/dev/null || true; ok "stopped old local server process"
fi

if command -v docker >/dev/null 2>&1 && docker_ready; then
  for p in "${COMPOSE_PROJECTS[@]}"; do
    # dummy values so compose can read the files even if .env is missing/incomplete
    SERVER_HOST=x SERVER_DOMAIN=x docker compose -p "$p" "${compose_files[@]}" down --volumes --rmi local --remove-orphans 2>/dev/null \
      && ok "docker project '$p' removed" || true
  done
  # anything left over that was clearly created by this project's compose files
  for v in $(docker volume ls -q 2>/dev/null | grep -E '(^|_)(personal_ai_data|caddy_data|caddy_config)$' || true); do
    case "$v" in personal-ai_*|docker_*) docker volume rm -f "$v" >/dev/null 2>&1 && ok "removed volume $v" ;; esac
  done
else
  warn "Docker isn't running, so Docker cleanup was skipped (nothing was running from it)."
fi

rm -rf .venv .venv-agent .pytest_cache data
find . -name __pycache__ -type d -prune -exec rm -rf {} + 2>/dev/null || true
ok "removed .venv, caches and ./data"

# ---------------------------------------------------------------- fresh Python env
step "Creating a fresh virtual environment"
"$PY" -m venv .venv
# shellcheck disable=SC1091
source .venv/bin/activate
python -m pip install --quiet --upgrade pip
python -m pip install --quiet -r requirements-dev.txt || die "pip install failed (see the message above). If it names 'mcp', send me that error."
ok "dependencies installed ($(python --version))"

# ---------------------------------------------------------------- .env
step ".env"
if [[ $RESET_ENV -eq 1 ]]; then rm -f .env; fi
detect_ip() { ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1 2>/dev/null || true; }
[[ -n "$HOST_IP" ]] || HOST_IP="$(detect_ip)"
[[ -n "$HOST_IP" ]] || HOST_IP="127.0.0.1"
if [[ ! -f .env ]]; then
  python scripts/gen_env.py --host "$HOST_IP"
  # first run: no model needed. Switch to ollama/openai later in .env (SETUP.md section 6).
  perl -pi -e 's/^CHAT_LLM_PROVIDER=.*/CHAT_LLM_PROVIDER=echo/' .env
  warn "CHAT_LLM_PROVIDER set to 'echo' (no real model yet). Change it in .env when ready, then restart."
else
  ok ".env kept"
  OLD_HOST="$(grep -E '^SERVER_HOST=' .env | head -1 | cut -d= -f2- | sed 's/[[:space:]#].*//')"
  if [[ -z "$OLD_HOST" || ( "$OLD_HOST" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ && "$OLD_HOST" != "$HOST_IP" ) ]]; then
    perl -pi -e "s/^SERVER_HOST=.*/SERVER_HOST=$HOST_IP/" .env
    ok "SERVER_HOST set to $HOST_IP (was '${OLD_HOST:-empty}')"
  fi
fi
SERVER_HOST_VAL="$(grep -E '^SERVER_HOST=' .env | head -1 | cut -d= -f2- | sed 's/[[:space:]#].*//')"
python scripts/invite_code.py --ensure --quiet || true      # older .env files have no invite code
INVITE_VAL="$(grep -E '^INVITE_CODE=' .env | head -1 | cut -d= -f2- | sed 's/[[:space:]#].*//')"
[[ -n "$SERVER_HOST_VAL" ]] || SERVER_HOST_VAL="$HOST_IP"

# ---------------------------------------------------------------- tests
if [[ $SKIP_TESTS -ne 1 ]]; then
  step "Running tests"
  if python -m pytest -q; then ok "tests passed"
  else die "Tests failed - not starting. Fix or re-run with --skip-tests. (Send me the failure output and I'll fix the code.)"; fi
fi

# ---------------------------------------------------------------- start
mkdir -p data
if [[ "$MODE" == "docker" ]]; then
  step "Building and starting Docker (this takes a few minutes the first time)"
  (cd docker && docker compose -p personal-ai --env-file ../.env "${compose_files[@]/docker\//}" up -d --build)
  URL="https://$SERVER_HOST_VAL:8443"
  HEALTH_CMD=(curl -ksS --max-time 3 "$URL/healthz")
else
  step "Starting the server locally"
  nohup python -m app.main > data/server.log 2>&1 &
  echo $! > data/server.pid
  URL="http://127.0.0.1:8001"
  HEALTH_CMD=(curl -sS --max-time 3 "$URL/healthz")
fi

step "Waiting for the server to answer"
ERRF="$(mktemp)"
for i in $(seq 1 40); do
  if out="$("${HEALTH_CMD[@]}" 2>"$ERRF")" && [[ "$out" == *'"ok"'* ]]; then
    ok "server is up: $out"; UP=1; break
  fi
  sleep 3; printf "."
done; echo
if [[ "${UP:-0}" -ne 1 ]]; then
  echo "Last curl error: $(tail -1 "$ERRF")"
  if [[ "$MODE" == "docker" ]]; then
    echo "Last server logs:"; (cd docker && docker compose -p personal-ai --env-file ../.env -f docker-compose.yml -f docker-compose.local.yml logs --tail 40 personal-ai-mcp caddy) || true
    if (cd docker && docker compose -p personal-ai --env-file ../.env -f docker-compose.yml -f docker-compose.local.yml exec -T personal-ai-mcp python -c "import urllib.request;urllib.request.urlopen('http://127.0.0.1:8001/healthz',timeout=3)") >/dev/null 2>&1; then
      echo "Diagnosis: the Python server is OK; the HTTPS address $URL is not reachable. Check SERVER_HOST in .env against: ipconfig getifaddr en0"
    else
      echo "Diagnosis: the Python server itself is not answering - see the traceback above."
    fi
  else
    echo "Last server logs:"; tail -40 data/server.log || true
  fi
  die "The server did not become healthy. See the logs above."
fi

cat <<EOF

${G}${B}Done.${N}
  Server address for the Node app:  ${B}$URL${N}
  Invite code (register screen):    ${B}${INVITE_VAL:-none}${N}
  Stop:     $([[ "$MODE" == "docker" ]] && echo "cd docker && docker compose -p personal-ai --env-file ../.env -f docker-compose.yml -f docker-compose.local.yml down" || echo "kill \$(cat data/server.pid)")
  Logs:     $([[ "$MODE" == "docker" ]] && echo "cd docker && docker compose -p personal-ai logs -f personal-ai-mcp" || echo "tail -f data/server.log")
  Next:     create your account and connect the app -> SETUP.md sections 5 and 7
$([[ "$MODE" == "local" ]] && echo "  Note:     local mode has NO HTTPS, and the app refuses http://. Use docker mode for the app.")
EOF
