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

# compose <args...> — engine-correct compose, with the podman override when needed.
compose() {
  local eng; eng="$(engine)"
  local files=(-f "$COMPOSE_FILE")
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
    down)            compose --profile full down ;;
    restart)         compose --profile full restart "$@" ;;
    rebuild)         cmd_rebuild "$@" ;;
    reset)           cmd_reset "$@" ;;
    logs)            compose --profile full logs -f "$@" ;;
    status)          compose --profile full ps ;;
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

# cmd_backend_boot — backend container entrypoint. Runs in-container: mix direct,
# binds 0.0.0.0 so the published port is reachable from the host.
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
  log "Booting Phoenix on 0.0.0.0:$PORT…"
  exec mix run --no-start --no-halt \
    -e "SymphonyElixir.Workflow.set_workflow_file_path(\"$WORKFLOW_FILE\"); {:ok, _} = Application.ensure_all_started(:symphony_elixir)"
}

# preflight_full — fail fast with a clear hint before bringing the stack up.
preflight_full() {
  port_in_use "$PORT"      && die "Port $PORT (backend) is in use. Stop it or set HARMONY_PORT=<free>."
  port_in_use "$VITE_PORT" && die "Port $VITE_PORT (vite) is in use. Stop whatever holds it."
  return 0
}

print_banner() {
  cat <<EOF

  ┌─ Harmony (full / containers) is up ──────────
  │  App (open this)  →  http://localhost:$VITE_PORT/   (Vite, HMR)
  │  JSON API         →  http://localhost:$PORT/api/v1/
  │  Socket           →  ws://localhost:$PORT/socket
  │
  │  In full mode the SPA is served by Vite (:$VITE_PORT); the backend
  │  (:$PORT) serves API + socket. Edit frontend → instant HMR. Edit
  │  backend (.ex) → ./dev/harmony.sh restart backend.
  │
  │  Logs: ./dev/harmony.sh logs   Stop: ./dev/harmony.sh down
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
    compose --profile full up -d
    print_banner
  else
    log "Starting full stack (Ctrl+C to stop)…"
    print_banner
    compose --profile full up
  fi
}

main "$@"
