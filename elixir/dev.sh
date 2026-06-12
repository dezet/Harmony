#!/usr/bin/env bash
#
# Harmony local dev launcher — ONE command for frontend/backend work.
#
#   ./dev.sh
#
# Brings up, idempotently:
#   1. Postgres        (docker compose, with a plain-container fallback)
#   2. Databases       (harmony_dev + harmony_test, created + migrated)
#   3. Frontend assets (npm deps + vite build → priv/static/app)
#   4. Backend         (Phoenix on :$PORT, serving the React SPA + JSON API + socket)
#   5. Vite HMR        (live frontend on :5173, proxying /api + /socket to the backend)
#
# It boots with a `tracker: kind: memory` workflow, so it needs NO Linear
# credentials and NO Codex — the orchestrator never finds a candidate issue and
# never dispatches an agent. This is the dev counterpart of the production
# `./bin/symphony ./WORKFLOW.md` boot.
#
# One Ctrl+C tears down both the backend and Vite.
#
# Knobs (env vars):
#   PORT=4010        backend / SPA / API / socket port
#   DB_PORT=5432     Postgres port
#   DOCKER=docker    container engine (set DOCKER=podman for Podman)
#   SKIP_DB=1        assume Postgres is already up + migrated
#   SKIP_ASSETS=1    skip npm install + vite build (faster restarts)
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

PORT="${PORT:-4010}"
DB_PORT="${DB_PORT:-5432}"
DOCKER="${DOCKER:-docker}"
PG_CONTAINER="harmony-postgres"
PG_VOLUME="harmony_postgres_data"
WORKFLOW_FILE="$SCRIPT_DIR/.dev-workflow.md"
MIX=(mise exec -- mix)

log()  { printf '\033[1;36m[dev]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[dev] ERROR:\033[0m %s\n' "$*" >&2; exit 1; }

# retry <max-attempts> <command...> — re-runs until success or attempts exhausted.
retry() {
  local max="$1"; shift; local n=1
  until "$@"; do
    [ "$n" -ge "$max" ] && return 1
    n=$((n + 1)); sleep 2
  done
}

# port_in_use <port> — true if something already accepts connections there.
# (A plain TCP connect is the right tool for "is a listener present"; we only
# avoid it for gauging a *starting* server's readiness.)
port_in_use() { (exec 3<>"/dev/tcp/127.0.0.1/$1") 2>/dev/null; }

# --- preconditions ---------------------------------------------------------
command -v mise >/dev/null 2>&1 || die "mise not found — install it (manages Erlang/Elixir)."
command -v npm  >/dev/null 2>&1 || die "npm not found — install Node.js."
if [ "${SKIP_DB:-0}" != "1" ]; then
  command -v "$DOCKER" >/dev/null 2>&1 || die "'$DOCKER' not found — set DOCKER=podman or SKIP_DB=1."
fi
port_in_use "$PORT" && die "Port $PORT is already in use (another dev server / stray backend?). Stop it, or run with PORT=<free port>."

# --- 1. Postgres -----------------------------------------------------------
# Ask Postgres itself whether it accepts connections. Raw /dev/tcp is unreliable
# here: the container's published port answers before the server does (and
# first-boot initdb briefly restarts the server), so a TCP connect reports
# "ready" too early. pg_isready performs a real startup handshake instead.
pg_ready() {
  if "$DOCKER" exec "$PG_CONTAINER" pg_isready -q >/dev/null 2>&1; then
    return 0
  fi
  if command -v pg_isready >/dev/null 2>&1; then
    pg_isready -h 127.0.0.1 -p "$DB_PORT" -q >/dev/null 2>&1 && return 0
  fi
  return 1
}

start_pg() {
  log "Starting Postgres…"
  # docker compose also seeds harmony_test via its init SQL — preferred.
  if HARMONY_DATABASE_PORT="$DB_PORT" "$DOCKER" compose up -d postgres >/dev/null 2>&1; then
    log "Postgres started via docker compose."
  else
    log "compose unavailable (bind-mount denied?) — using a plain container instead."
    "$DOCKER" rm -f "$PG_CONTAINER" >/dev/null 2>&1 || true
    "$DOCKER" run -d --name "$PG_CONTAINER" \
      -e POSTGRES_USER=postgres -e POSTGRES_PASSWORD=postgres -e POSTGRES_DB=harmony_dev \
      -p "$DB_PORT:5432" -v "$PG_VOLUME:/var/lib/postgresql/data" \
      docker.io/library/postgres:16-alpine >/dev/null \
      || die "Could not start Postgres container."
  fi
}

wait_pg() {
  log "Waiting for Postgres on :$DB_PORT…"
  for _ in $(seq 1 30); do
    pg_ready && return 0
    sleep 1
  done
  die "Postgres did not become ready in time."
}

if [ "${SKIP_DB:-0}" = "1" ]; then
  log "SKIP_DB=1 — skipping Postgres + migrations."
else
  if pg_ready; then
    log "Postgres already reachable on :$DB_PORT."
  else
    start_pg
    wait_pg
  fi
  # ecto.create is idempotent; covers both compose and plain-container cases.
  # Retry through the brief first-boot window where initdb restarts the server
  # and an otherwise-ready connection can be dropped.
  log "Ensuring databases + running migrations…"
  retry 15 env "${MIX[@]}" ecto.create        || die "ecto.create (dev) failed."
  retry 15 env MIX_ENV=test "${MIX[@]}" ecto.create || die "ecto.create (test) failed."
  "${MIX[@]}" ecto.migrate
  MIX_ENV=test "${MIX[@]}" ecto.migrate
fi

# --- 2. Frontend assets ----------------------------------------------------
if [ "${SKIP_ASSETS:-0}" = "1" ]; then
  log "SKIP_ASSETS=1 — skipping npm install + vite build."
else
  if [ ! -d assets/node_modules ]; then
    log "Installing frontend dependencies (npm ci)…"
    "${MIX[@]}" assets.setup
  fi
  log "Building the SPA (vite build → priv/static/app)…"
  "${MIX[@]}" assets.build
fi

# --- 3. Dev workflow (memory tracker, regenerated each run from $PORT) ------
log "Writing dev workflow → ${WORKFLOW_FILE#$SCRIPT_DIR/} (tracker: memory, server :$PORT)"
cat > "$WORKFLOW_FILE" <<EOF
---
# Generated by dev.sh — gitignored, safe to delete. Memory tracker means the
# orchestrator polls an empty in-memory issue list, so no Linear / Codex needed.
tracker:
  kind: memory
polling:
  interval_ms: 60000
workspace:
  root: ${TMPDIR:-/tmp}/harmony-dev-workspaces
agent:
  backend: codex
  max_concurrent_agents: 1
  max_turns: 1
codex:
  command: "true"
observability:
  dashboard_enabled: true
server:
  port: $PORT
  host: 127.0.0.1
---

Harmony local dev server — memory tracker, no issues, no dispatch.
EOF

# --- 4. Boot backend + Vite, one Ctrl+C tears down both --------------------
# Job control: each background job below becomes its own process group, so on
# shutdown we can signal the WHOLE tree (mise → mix → beam.smp, npm → vite)
# instead of orphaning grandchildren like the beam VM.
set -m

BACKEND_PID=""
VITE_PID=""
stop_group() { [ -n "$1" ] && kill -TERM -"$1" >/dev/null 2>&1 || true; }
cleanup() {
  trap - INT TERM EXIT
  log "Shutting down…"
  stop_group "$VITE_PID"
  stop_group "$BACKEND_PID"
  wait >/dev/null 2>&1 || true
}
trap cleanup INT TERM EXIT

log "Booting backend on :$PORT…"
# --no-start so we can point Symphony at the dev workflow BEFORE the app starts.
mise exec -- mix run --no-start --no-halt \
  -e "SymphonyElixir.Workflow.set_workflow_file_path(\"$WORKFLOW_FILE\"); {:ok, _} = Application.ensure_all_started(:symphony_elixir)" &
BACKEND_PID=$!

log "Booting Vite HMR on :5173…"
( cd assets && HARMONY_PORT="$PORT" npm run dev ) &
VITE_PID=$!

cat <<EOF

  ┌─ Harmony dev is up ──────────────────────────
  │  Frontend (HMR)   →  http://localhost:5173/  (Vite prints its real URL
  │                       below; it shifts port if 5173 is taken)
  │  Backend + SPA    →  http://127.0.0.1:$PORT/
  │  JSON API         →  http://127.0.0.1:$PORT/api/v1/
  │  Socket           →  ws://127.0.0.1:$PORT/socket
  │
  │  Ctrl+C stops both the backend and Vite.
  └──────────────────────────────────────────────

EOF

# Exit (and trigger cleanup) as soon as either process stops.
wait -n "$BACKEND_PID" "$VITE_PID" 2>/dev/null || wait
