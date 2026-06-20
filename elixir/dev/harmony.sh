#!/usr/bin/env bash
#
# Harmony dev CLI — one command for the whole container environment.
#
#   ./dev/harmony.sh up            # default: whole stack in containers + hot reload
#   ./dev/harmony.sh up --host     # legacy host flow (backend+vite on host)
#   ./dev/harmony.sh down | rebuild | reset | logs | status | restart
#   ./dev/harmony.sh migrate | test | iex | psql | exec <svc> <cmd...>
#
# Engine: auto-detects podman → docker; override with ENGINE=docker.
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_DIR"

PORT="${HARMONY_PORT:-4010}"
DB_PORT="${HARMONY_DATABASE_PORT:-5432}"
VITE_PORT=5173
COMPOSE_FILE="$PROJECT_DIR/docker-compose.yml"
PODMAN_OVERRIDE="$PROJECT_DIR/dev/docker-compose.podman.yml"
WORKFLOW_FILE="$PROJECT_DIR/.dev-workflow.md"
CLOAK_KEY_FILE="$PROJECT_DIR/.dev-cloak-key"

log() { printf '\033[1;36m[harmony]\033[0m %s\n' "$*"; }
die() { printf '\033[1;31m[harmony] ERROR:\033[0m %s\n' "$*" >&2; exit 1; }

# retry <max> <cmd...> — re-run until success or attempts exhausted.
retry() {
  local max="$1"; shift; local n=1
  until "$@"; do
    [ "$n" -ge "$max" ] && return 1
    n=$((n + 1)); sleep 2
  done
}

# port_in_use <port> — true if something already accepts connections there.
port_in_use() { (exec 3<>"/dev/tcp/127.0.0.1/$1") 2>/dev/null; }

# dev_cloak_key — a stable local CLOAK_KEY for the dev environment. The Vault
# (SymphonyElixir.Vault) reads CLOAK_KEY at boot in EVERY env (fail-fast, no
# default). Honors an operator-set CLOAK_KEY; otherwise generates one once and
# persists it (gitignored) so the dev database stays readable across restarts.
dev_cloak_key() {
  if [ -n "${CLOAK_KEY:-}" ]; then printf '%s' "$CLOAK_KEY"; return; fi
  if [ -s "$CLOAK_KEY_FILE" ]; then cat "$CLOAK_KEY_FILE"; return; fi
  local key; key="$(head -c 32 /dev/urandom | base64 | tr -d '\n')"
  printf '%s' "$key" > "$CLOAK_KEY_FILE"
  printf '%s' "$key"
}

# detect_engine — ENGINE override, else podman, else docker.
detect_engine() {
  if [ -n "${ENGINE:-}" ]; then printf '%s' "$ENGINE"; return; fi
  command -v podman >/dev/null 2>&1 && { printf 'podman'; return; }
  command -v docker >/dev/null 2>&1 && { printf 'docker'; return; }
  die "no container engine found — install podman or docker (or set ENGINE=)."
}

# engine — resolve the container engine lazily and memoize into ENGINE.
# Detection is deferred (NOT run at load time) so in-container subcommands like
# __backend-boot, which run where no podman/docker exists, never trigger it.
engine() {
  [ -n "${ENGINE:-}" ] || ENGINE="$(detect_engine)"
  printf '%s' "$ENGINE"
}

# compose <args...> — engine-correct compose, with the podman override when
# needed. Always selects the `full` profile so profiled services (backend,
# frontend) are visible to every subcommand — notably `exec`, which podman-compose
# otherwise reports as a missing service. Naming a service (e.g. `up postgres`)
# still scopes the action to that one service.
compose() {
  local eng; eng="$(engine)"
  local files=(--profile full -f "$COMPOSE_FILE")
  [ "$eng" = "podman" ] && files+=(-f "$PODMAN_OVERRIDE")
  if "$eng" compose version >/dev/null 2>&1; then
    "$eng" compose "${files[@]}" "$@"
  elif command -v "${eng}-compose" >/dev/null 2>&1; then
    "${eng}-compose" "${files[@]}" "$@"
  else
    die "no compose provider for '$eng' — install '$eng compose' or '${eng}-compose'."
  fi
}

usage() {
  local eng="${ENGINE:-$(detect_engine 2>/dev/null || true)}"
  cat <<EOF
Harmony dev CLI (engine: ${eng:-none})

  up [--host] [-d]   bring up the stack (default: full, containers + hot reload)
  down               stop the stack (keeps volumes/DB)
  restart [svc]      restart a service, or the whole stack
  rebuild [svc]      rebuild container image(s); volumes/DB untouched
  reset              DESTROY volumes (DB + deps + _build + node_modules); asks first
  logs [svc]         follow logs
  status             list services
  migrate            run ecto migrations (dev + test) in the backend container
  test [--fe]        mix test in backend (--fe → npm test in frontend)
  iex                IEx shell in the backend container
  psql               psql into the postgres container
  exec <svc> <cmd…>  run a command in a service
  help               this message
EOF
}

main() {
  local cmd="${1:-up}"; shift || true
  case "$cmd" in
    up)              cmd_up "$@" ;;
    down)            compose down ;;
    restart)         compose restart "$@" ;;
    rebuild)         cmd_rebuild "$@" ;;
    reset)           cmd_reset "$@" ;;
    logs)            compose logs -f "$@" ;;
    status)          compose ps ;;
    migrate)         cmd_migrate ;;
    test)            cmd_test "$@" ;;
    iex)             compose exec backend iex -S mix run --no-start ;;
    psql)            compose exec postgres psql -U postgres harmony_dev ;;
    exec)            compose exec "$@" ;;
    __backend-boot)  cmd_backend_boot ;;
    help|-h|--help)  usage ;;
    *)               die "unknown command: $cmd (try: ./dev/harmony.sh help)" ;;
  esac
}

# write_dev_workflow <bind-host> — regenerate the gitignored dev workflow.
# Memory tracker → orchestrator polls an empty issue list (no Linear/Codex).
write_dev_workflow() {
  local host="$1"
  cat > "$WORKFLOW_FILE" <<EOF
---
# Generated by dev/harmony.sh — gitignored, safe to delete.
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
  host: $host
---

Harmony local dev server — memory tracker, no issues, no dispatch.
EOF
}

# start_app — boot the BEAM in the background, in its own process group so a
# restart can signal the whole tree (elixir → erl → beam.smp). Sets APP_PID.
APP_PID=""
start_app() {
  mix run --no-start --no-halt \
    -e "SymphonyElixir.Workflow.set_workflow_file_path(\"$WORKFLOW_FILE\"); {:ok, _} = Application.ensure_all_started(:symphony_elixir)" &
  APP_PID=$!
}

# stop_app — terminate the running app's whole process group, then reap it.
stop_app() {
  [ -n "$APP_PID" ] || return 0
  kill -TERM -"$APP_PID" 2>/dev/null || kill -TERM "$APP_PID" 2>/dev/null || true
  wait "$APP_PID" 2>/dev/null || true
  APP_PID=""
}

# wait_for_source_change — block until a .ex/.exs file under lib/ or config/
# changes, then debounce by draining further events until ~1s of quiet. Filtering
# to .exs? avoids spurious restarts from editor temp files; recompile output lands
# in the _build volume (outside lib/config), so it never self-triggers.
wait_for_source_change() {
  local watch=(-q -r -e modify,create,delete,move --include '\.exs?$' lib config)
  inotifywait "${watch[@]}" >/dev/null 2>&1 || true
  while inotifywait -t 1 "${watch[@]}" >/dev/null 2>&1; do :; done
}

# cmd_backend_boot — backend container entrypoint. Runs in-container: mix direct,
# binds 0.0.0.0 so the published port is reachable from the host. Auto-restarts
# the app on backend source changes (idiomatic hot reload for an OTP app).
cmd_backend_boot() {
  # Install hex/rebar into MIX_HOME (a named volume) — the image's build-time
  # copy lives under /root, unreadable once keep-id maps us to the host uid.
  log "Ensuring hex + rebar…"
  mix local.hex --force >/dev/null
  mix local.rebar --force >/dev/null
  log "Fetching deps…"
  mix deps.get
  log "Ensuring databases + migrating (dev + test)…"
  retry 15 mix ecto.create
  retry 15 env MIX_ENV=test mix ecto.create
  mix ecto.migrate
  MIX_ENV=test mix ecto.migrate
  write_dev_workflow "0.0.0.0"

  set -m  # job control: background jobs get their own process group for clean kill
  trap 'log "Shutting down backend…"; stop_app; exit 0' TERM INT
  while true; do
    log "Booting Phoenix on 0.0.0.0:$PORT (auto-restart on .ex/.exs change)…"
    start_app
    wait_for_source_change
    log "Backend source changed — restarting…"
    stop_app
  done
}

# preflight_full — fail fast with a clear hint before bringing the stack up.
preflight_full() {
  port_in_use "$PORT"      && die "Port $PORT (backend) is in use. Stop it or set HARMONY_PORT=<free>."
  port_in_use "$VITE_PORT" && die "Port $VITE_PORT (vite) is in use. Stop whatever holds it."
  return 0
}

# print_banner [full|host] — the post-boot summary. The SPA is always served by
# Vite (:$VITE_PORT); the backend (:$PORT) serves API + socket. Only the backend
# reload story and the stop hint differ between modes.
print_banner() {
  local mode="${1:-full}" title reload stop
  if [ "$mode" = "host" ]; then
    title="Harmony (host) is up"
    reload="Edit backend (.ex) → Ctrl+C, then ./dev/harmony.sh up --host."
    stop="Stop: Ctrl+C (stops backend + Vite)."
  else
    title="Harmony (full / containers) is up"
    reload="Edit backend (.ex) → it recompiles and auto-restarts (~seconds)."
    stop="Logs: ./dev/harmony.sh logs   Stop: ./dev/harmony.sh down"
  fi
  cat <<EOF

  ┌─ $title
  │  App (open this)  →  http://localhost:$VITE_PORT/   (Vite, HMR)
  │  JSON API         →  http://localhost:$PORT/api/v1/
  │  Socket           →  ws://localhost:$PORT/socket
  │
  │  Edit frontend → instant HMR.
  │  $reload
  │
  │  $stop
  └──────────────────────────────────────────────

EOF
}

# cmd_up [--host] [-d]
cmd_up() {
  local detached=0 host_mode=0
  for a in "$@"; do
    case "$a" in
      --host) host_mode=1 ;;
      -d|--detach) detached=1 ;;
      *) die "up: unknown flag '$a'" ;;
    esac
  done

  if [ "$host_mode" = 1 ]; then
    cmd_up_host        # implemented in a later task
    return
  fi

  preflight_full
  export CLOAK_KEY="$(dev_cloak_key)"
  if [ "$detached" = 1 ]; then
    log "Starting full stack (detached)…"
    compose up -d
    print_banner
  else
    log "Starting full stack (Ctrl+C to stop)…"
    print_banner
    compose up
  fi
}

# cmd_rebuild [svc] — rebuild image(s) from scratch. DB + deps/_build volumes kept.
cmd_rebuild() {
  log "Rebuilding image(s)${1:+ for $1} (no cache)…"
  compose build --no-cache "$@"
  log "Done. Run './dev/harmony.sh up' to start the rebuilt stack."
}

# cmd_reset — destroy ALL named volumes (DB, deps, _build, node_modules). Destructive.
cmd_reset() {
  printf '\033[1;31m[harmony]\033[0m This DELETES the database and all build caches (deps, _build, node_modules).\n'
  read -r -p "Type 'reset' to confirm: " reply
  [ "$reply" = "reset" ] || die "Aborted."
  log "Stopping stack and removing volumes…"
  compose down -v
  log "Clean slate. Next './dev/harmony.sh up' re-creates the DB and recompiles."
}

# cmd_migrate — run migrations for dev + test in the backend container.
cmd_migrate() {
  log "Migrating dev + test databases…"
  compose exec backend mix ecto.migrate
  compose exec backend env MIX_ENV=test mix ecto.migrate
}

# cmd_test [--fe] — backend mix test, or frontend npm test with --fe.
cmd_test() {
  if [ "${1:-}" = "--fe" ]; then
    compose exec frontend npm test
  else
    compose exec backend mix test
  fi
}

# cmd_up_host — legacy host flow: Postgres in a container, backend + Vite on the
# host via mise/npm. Fast, no image builds. One Ctrl+C tears down both. Like the
# container path it auto-provides a dev CLOAK_KEY, so no manual export is needed.
# Note: host mode has no source watcher — backend changes need a manual restart.
cmd_up_host() {
  command -v mise >/dev/null 2>&1 || die "mise not found — needed for host mode (manages Erlang/Elixir)."
  command -v npm  >/dev/null 2>&1 || die "npm not found — install Node.js for host mode."
  port_in_use "$PORT" && die "Port $PORT is in use. Stop it or set HARMONY_PORT=<free>."

  local MIX=(mise exec -- mix)

  pg_ready() {
    compose exec -T postgres pg_isready -q >/dev/null 2>&1 && return 0
    command -v pg_isready >/dev/null 2>&1 && pg_isready -h 127.0.0.1 -p "$DB_PORT" -q >/dev/null 2>&1 && return 0
    return 1
  }

  if pg_ready; then
    log "Postgres already reachable on :$DB_PORT."
  else
    log "Starting Postgres (container)…"
    compose up -d postgres >/dev/null 2>&1 || die "Could not start Postgres."
    log "Waiting for Postgres…"
    for _ in $(seq 1 30); do pg_ready && break; sleep 1; done
    pg_ready || die "Postgres did not become ready in time."
  fi

  export CLOAK_KEY="$(dev_cloak_key)"

  log "Ensuring databases + migrating (dev + test)…"
  retry 15 env "${MIX[@]}" ecto.create
  retry 15 env MIX_ENV=test "${MIX[@]}" ecto.create
  "${MIX[@]}" ecto.migrate
  MIX_ENV=test "${MIX[@]}" ecto.migrate

  if [ ! -d assets/node_modules ]; then
    log "Installing frontend deps…"
    "${MIX[@]}" assets.setup
  fi
  log "Building the SPA…"
  "${MIX[@]}" assets.build

  write_dev_workflow "127.0.0.1"

  set -m  # job control: each background job gets its own process group.
  local BACKEND_PID="" VITE_PID=""
  stop_group() { [ -n "$1" ] && kill -TERM -"$1" >/dev/null 2>&1 || true; }
  cleanup() {
    trap - INT TERM EXIT
    log "Shutting down…"
    stop_group "$VITE_PID"; stop_group "$BACKEND_PID"
    wait >/dev/null 2>&1 || true
  }
  trap cleanup INT TERM EXIT

  log "Booting backend on :$PORT…"
  mise exec -- mix run --no-start --no-halt \
    -e "SymphonyElixir.Workflow.set_workflow_file_path(\"$WORKFLOW_FILE\"); {:ok, _} = Application.ensure_all_started(:symphony_elixir)" &
  BACKEND_PID=$!

  log "Booting Vite HMR on :$VITE_PORT…"
  ( cd assets && HARMONY_PORT="$PORT" npm run dev ) &
  VITE_PID=$!

  print_banner host
  wait -n "$BACKEND_PID" "$VITE_PID" 2>/dev/null || wait
}

main "$@"
