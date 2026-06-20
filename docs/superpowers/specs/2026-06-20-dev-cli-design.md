# Dev CLI (`dev/harmony.sh`) — Design

**Date:** 2026-06-20
**Status:** Approved (design) — pending implementation plan

## Goal

One developer CLI that manages the project's container environment: bring the
whole stack up, tear it down, rebuild, and run everyday tasks against it. The
default mode runs the **entire stack in containers with hot reload** (Phoenix
code-reload + Vite HMR), with the existing host-based flow preserved as an
opt-in mode.

This consolidates the existing `elixir/dev.sh` into a single script. After this
work there is exactly **one** dev script.

## Decisions (settled during brainstorming)

| Topic | Decision |
|---|---|
| Script | Single bash script at `elixir/dev/harmony.sh`. No `.ps1`. |
| Old `dev.sh` | Logic absorbed into `harmony.sh`; `elixir/dev.sh` is **deleted**. |
| Default mode | `full` — all services in containers with hot reload. |
| Host mode | Available via `up --host` (the old `dev.sh` flow, merged in). |
| Container engine | Auto-detect `podman` → `docker`; override with `ENGINE=`. |
| Compose structure | Extend the existing `docker-compose.yml` with a `full` profile. |
| Command set | Lifecycle **+** everyday tasks (migrate/test/iex/psql/exec). |
| Container entrypoint | Hidden subcommand of the same script (`__backend-boot`) — no separate `entrypoint.sh`. |

## Scope note (honest framing)

This is **not just a script**. The script is the thin part. The deliverables are:

- `elixir/dev/harmony.sh` — the single CLI (host + full modes, all subcommands,
  and the in-container boot subcommand).
- `elixir/dev/Dockerfile.dev` — backend dev image (Elixir 1.19.5 / Erlang 28,
  matching `mise.toml`, plus git + build tools).
- `elixir/docker-compose.yml` — extended with `backend` + `frontend` services
  under a `full` profile and named volumes for build artifacts.
- `elixir/assets/vite.config.ts` — small tweak so the Vite proxy can reach the
  backend container by service name.
- Deletion of `elixir/dev.sh`.

Host mode already gives working hot reload today; full-container mode is a real
step up in complexity. The frontend does **not** need its own Dockerfile — it
uses a stock `node:22-alpine` image.

## File layout

```
elixir/
├─ docker-compose.yml      # EXTENDED: + backend, + frontend (profile "full") + named volumes
├─ dev/
│  ├─ harmony.sh           # THE script: host-mode + full-mode + all subcommands + __backend-boot
│  └─ Dockerfile.dev       # backend dev image (elixir 1.19.5 / erlang 28 + git/build tools)
├─ dev.sh                  # DELETED (logic moved into dev/harmony.sh)
└─ assets/vite.config.ts   # small tweak (HARMONY_BACKEND_HOST + server.host)
```

Optional follow-up (not required): a thin `./dev` wrapper at the repo root that
delegates to `elixir/dev/harmony.sh`.

## Container architecture (full mode)

Three services. Source bind-mounted; build artifacts in **named volumes** (the
core trick that makes in-container hot reload work without host/arch conflicts).

| Service | Image | Source bind | Named volume (artifacts) | Port | Networking |
|---|---|---|---|---|---|
| `postgres` | `postgres:16-alpine` | — | `harmony_postgres_data → /var/lib/postgresql/data` | 5432 | — (default profile) |
| `backend` | `dev/Dockerfile.dev` | `./:/app` `:U` | `harmony_deps → /app/deps`, `harmony_build → /app/_build` | 4010 | `HARMONY_DATABASE_HOST=postgres` |
| `frontend` | `node:22-alpine` | `./assets:/app/assets` `:U` | `harmony_node_modules → /app/assets/node_modules` | 5173 | `HARMONY_BACKEND_HOST=backend`, `HARMONY_PORT=4010` |

### Key technical points

- **Build artifacts as named volumes, never host bind mounts.** `deps`,
  `_build`, and `assets/node_modules` are container-owned named volumes layered
  over the bind-mounted source. The container compiles for its own arch; the
  host never clobbers compiled output. This is the whole trick.
- **Backend binds `host: 0.0.0.0`** in the generated dev workflow (not
  `127.0.0.1` like the old `dev.sh`), otherwise the host cannot reach the
  published port.
- **Vite proxy must target the backend by service name.** Today
  `assets/vite.config.ts` hardcodes `http://localhost:${HARMONY_PORT}` for
  `/api` and `/socket`. In full mode Vite runs in its own container, so
  `localhost` does not reach the backend. Tweak the target to
  `http://${process.env.HARMONY_BACKEND_HOST ?? "localhost"}:${process.env.HARMONY_PORT ?? "4000"}`
  and run Vite with `server.host: true` (e.g. `npm run dev -- --host`). Browser
  HMR works because `:5173` is published.
- **Rootless podman permissions.** Bind-mounted source uses the `:U` flag plus
  `userns_mode: keep-id` so container-written files match the host UID and the
  build user inside the container can write to mounted paths. The docker path
  does not need these flags; the script/compose apply them conditionally for the
  podman engine.
- **Startup ordering.** Postgres already has a healthcheck; `backend`
  `depends_on` it with `condition: service_healthy`. `frontend` `depends_on`
  backend.

### Backend boot (replicating the old `dev.sh` mechanism)

The Phoenix endpoint has `server: false` in `config.exs`; the server port/host
are **not** standard Phoenix config — the old `dev.sh` injects them via a
generated `.dev-workflow.md` (memory tracker, so no Linear/Codex needed) and
boots with `mix run --no-start -e "set_workflow_file_path(...); ensure_all_started"`.

The container entrypoint replicates this via the hidden `__backend-boot`
subcommand of `harmony.sh`, which on container start:

1. `mix deps.get` (into the `harmony_deps` volume) if needed.
2. `mix ecto.create` + `mix ecto.migrate` for dev and test (retried through the
   first-boot window, as the old `dev.sh` does).
3. Generates `.dev-workflow.md` with `tracker: memory`, `server.port: 4010`,
   `server.host: 0.0.0.0`.
4. Boots via `mix run --no-start -e "...set_workflow_file_path... ensure_all_started"`.

The script detects context: on the host it uses `mise exec -- mix`; inside the
container it calls `mix` directly (Elixir is installed in the image, no mise).

## Command surface

```
harmony.sh up [--host] [-d]   full (default) attached, Ctrl+C stops; --host → host flow; -d → detached
harmony.sh down               compose --profile full down (KEEPS volumes/DB)
harmony.sh restart [svc]      restart a service (or the whole stack)
harmony.sh rebuild [svc]      rebuild the IMAGE (after Dockerfile/deps change); volumes/DB untouched
harmony.sh reset              ⚠ remove named volumes (DB + deps + _build + node_modules) → from scratch; confirms first
harmony.sh logs [svc]         compose logs -f
harmony.sh status             compose ps
harmony.sh migrate            exec backend: mix ecto.migrate (dev + test)
harmony.sh test [--fe]        exec backend: mix test   (--fe → frontend: npm test)
harmony.sh iex                exec backend: IEx console
harmony.sh psql               exec postgres: psql harmony_dev
harmony.sh exec <svc> <cmd…>  passthrough to any service
harmony.sh help
```

### `rebuild` vs `reset` (deliberately distinct)

- **`rebuild`** — rebuild the container image (after a `Dockerfile.dev` / tooling
  change). Database data and compiled `deps`/`_build` volumes are **kept**.
- **`reset`** — destroy the named volumes → fresh database + fresh compilation.
  Destructive; prompts for confirmation.

## Engine detection, preflight, error handling

- **Engine:** `ENGINE` env overrides; otherwise auto-detect `podman` → `docker`.
  Compose invocation tries `$ENGINE compose`, falling back to
  `${ENGINE}-compose` (e.g. `podman-compose`).
- **Preflight (in `up`):** engine present? compose available? ports 4010 / 5173
  / 5432 free? source present? — clear `die` with a remediation hint, following
  the existing `dev.sh` conventions (`log`/`die`, `port_in_use`).
- **Podman vs docker flags** applied conditionally based on the detected engine.

## Modes

- **full (default):** `compose --profile full up` — postgres + backend +
  frontend, all hot-reloading. Attached so Ctrl+C tears down; `-d` detaches.
- **host (`up --host`):** the old `dev.sh` flow merged in — Postgres in a
  container (DB-only, default compose profile), backend + Vite on the host via
  `mise`/`npm`. Fast, no image builds.

## Verification

Shell orchestration is verified by a manual smoke test (documented, not
automated — YAGNI):

1. `harmony.sh up` → wait for "stack up" banner.
2. `curl` the backend on `:4010` and Vite on `:5173` → both respond.
3. Edit a `.tsx` file → browser HMR updates without reload.
4. Edit a `.ex` file → Phoenix code-reload picks it up.
5. `harmony.sh down` → stack stops, volumes preserved; `harmony.sh up` again is
   fast (artifacts cached in named volumes).
6. `harmony.sh reset` → confirms, wipes volumes, next `up` re-creates DB + deps.

## Out of scope (YAGNI)

- A `.ps1` / Windows-native script.
- Production container images / multi-stage release builds.
- Automated tests for the shell script itself.
- A root-level `./dev` wrapper (optional follow-up only).

## Implementation notes (deviations found during build)

These were discovered while integrating against the real app and live-verified
on podman 5.8.2 (rootless) on CachyOS. They refine the design above:

- **Lazy engine detection.** Engine detection must NOT run at script load — the
  backend container runs `harmony.sh __backend-boot` where no podman/docker
  exists. `engine()` resolves and memoizes lazily, only when `compose()` is
  actually called.
- **`CLOAK_KEY` is mandatory.** `SymphonyElixir.Vault` reads `CLOAK_KEY` at boot
  in every env (fail-fast, no default). The CLI generates a stable, gitignored
  dev key (`.dev-cloak-key`) and injects it into both the container and host
  flows, honoring an operator-set `CLOAK_KEY`. Without this the app crashes on
  boot. This was the original `dev.sh`'s implicit dependency on the operator's
  shell env.
- **`MIX_HOME`/`HEX_HOME` → the deps volume.** Under `keep-id` the container
  runs as the host uid and cannot write `$HOME=/root`, so hex/mix state would
  leak into the bind-mounted source. Both are pointed at `/app/deps/.*` (a named
  volume) and hex/rebar are installed at boot.
- **Full-mode entry is Vite (`:5173`), not the backend root.** In full mode the
  SPA is served by Vite with HMR; Phoenix serves only the API/socket, so
  `GET :4010/` is not a `200`. Readiness is checked via `GET :4010/api/v1/state`.
- **Backend hot reload = auto-restart on save.** This OTP app has no Phoenix
  code-reloader configured, and its work runs in long-lived GenServers where a
  module swap wouldn't suffice. `cmd_backend_boot` watches `lib/` + `config/`
  with `inotifywait` (debounced) and restarts the app on `.ex/.exs` changes.
  Host mode has no watcher (manual restart).
- **`--profile full` is injected centrally** in `compose()` because
  podman-compose does not see profiled services on `exec`/`migrate` unless the
  profile flag is present.
- **Host mode** was implemented and its routing/preflight verified, but a full
  host boot was not exercised on the build machine (no working host Elixir/npm).
  Container mode is the end-to-end-verified path.
