# React + WebSockets Frontend Design

## Purpose

This document defines the long-term target for Harmony's web frontend: replace the current Phoenix
LiveView UI with a React single-page application that talks to the backend over Phoenix Channels
(WebSockets) for real-time data and a JSON API for reads and writes. React becomes the strategic
frontend stack for Harmony, both to standardize on the React/TypeScript ecosystem and to support
richer client-side interactivity (live dashboard, work-run visualizations) than server-rendered
LiveView makes comfortable.

The scope of this spec is the **full replacement** of every current LiveView screen. Implementation
is staged (see [Migration Phases](#migration-phases)) so `main` stays shippable throughout, but the
spec describes the complete end state.

## Current Baseline

The web layer today is Phoenix LiveView, served over the LiveView socket at `/live`. There is **no
JavaScript build pipeline**: no `assets/`, no `package.json`, no esbuild/tailwind. Phoenix vendor JS
(`phoenix.js`, `phoenix_live_view.js`, `phoenix_html.js`) and a hand-written `dashboard.css` are
embedded at compile time and served through `StaticAssetController`; the root layout
(`lib/symphony_elixir_web/components/layouts.ex`) hand-writes the `<script>`/`<link>` tags and
initializes the LiveSocket inline. There is no `Plug.Static`.

Screens:

- `DashboardLive` (`/`) — renders the full `Presenter.state_payload/0` snapshot (status, metric
  cards, runtime/sandbox diagnostics, projects, rate limits, work runs, artifacts, running/blocked
  sessions, retry queue). Real-time updates work by signal: `ObservabilityPubSub` broadcasts the
  bare atom `:observability_updated` on topic `"observability:dashboard"`, and the LiveView reloads
  the full payload. A separate 1s `:runtime_tick` only refreshes elapsed-time/countdown displays.
- `ProjectsLive` (`/projects`) — lists projects.
- `ProjectFormLive` (`/projects/new`, `/projects/:id/edit`) — create/edit a project.

JSON API (`ObservabilityApiController`): `GET /api/v1/state` (returns the same `state_payload`),
`GET /api/v1/:issue_identifier`, `POST /api/v1/refresh`. Error envelope is `%{error: %{code,
message}}`. **There is no write API for projects** — create/update is reachable only through the
LiveView form (`Storage.upsert_project/1`).

Auth is effectively absent: a cookie session exists, browser routes have CSRF protection, the API is
public, and `check_origin: false`. The app runs in trusted environments (per the README preview
warning).

## Goals

- React (TypeScript) SPA as the only UI, served by Phoenix from the same origin (single deploy).
- Real-time dashboard delivered by a Phoenix Channel that pushes the existing `state_payload`.
- React Query as the single client-side source of truth; Channel pushes hydrate its cache.
- Project CRUD available over a JSON REST API (new), matching today's UI capabilities.
- A documented, typed wire contract shared between dashboard read (REST) and live push (Channel).
- Staged rollout that keeps `main` shippable and ends with LiveView fully removed.

## Non-Goals (YAGNI)

- No project **delete** endpoint — today's UI has no delete. Add later only if needed.
- No new authentication/authorization scheme. Keep the current (open, trusted-env) posture; only
  leave a seam (socket `connect/3`, optional API plug) for future auth.
- No theming/dark-mode work beyond what the default shadcn/ui theme provides.
- No payload/type codegen pipeline — TypeScript contract types are hand-written for now.
- No GraphQL, no separate frontend deployment/CDN, no CORS layer (same-origin only).

## Locked Decisions

These were settled during brainstorming and are fixed inputs to the plan:

1. **Motivation:** strategic React stack + rich interactivity. React displaces LiveView over time.
2. **Embedding:** single Phoenix deploy. React SPA lives in `elixir/assets/`, builds to
   `elixir/priv/static/app/`, served same-origin via `Plug.Static` + an `index.html` SPA fallback.
   Transport: Phoenix Channels (WS) + JSON API.
3. **Spec scope:** full replacement of all LiveView screens in one spec; implementation phased.
4. **Stack:** TypeScript + Vite + React Router + the official `phoenix` Channels client +
   React Hook Form + Yup (forms/validation) + React Query (REST data) + shadcn/ui (default
   `base-nova` style, built on Base UI + Tailwind v4).
5. **Real-time pattern:** the Channel pushes the full `state_payload`; a thin client writes it into
   the React Query cache via `setQueryData`. REST `GET /api/v1/state` handles initial load and
   reconnect. (Chosen over "Channel as invalidation signal" and "separate realtime store".)
6. **shadcn usage:** lean as hard as possible on the default shadcn theme. Do **not** write a custom
   component before checking whether shadcn already provides it.

## Target Architecture

```
Phoenix (Elixir)
  Orchestrator / Storage / PubSub --"observability:dashboard"--> ObservabilityChannel (socket "/socket")
  Presenter.state_payload/0  -->  GET /api/v1/state            (init / reconnect)   push "state"  --> WS
                             -->  ObservabilityChannel join ack + "state" pushes
  JSON API  /api/v1/state | /api/v1/:issue | /api/v1/refresh | /api/v1/projects (NEW CRUD)
  Plug.Static (priv/static/app) + SpaController (index.html fallback for non-API GET)

React SPA (TypeScript, served from priv/static/app)
  React Router: / , /projects , /projects/new , /projects/:id/edit
  React Query cache  <-- Channel "state" push hydrates (setQueryData)
  Forms: React Hook Form + Yup     UI: shadcn/ui + Tailwind (default theme)
```

Principles:

- Phoenix stops rendering UI. The router keeps only `/api/v1/*`, the `/socket` Channel, the GitHub
  webhook, and a **catch-all GET → `SpaController`** that returns `index.html`. All UI routing is
  client-side (React Router, same paths as today).
- The Channel and `GET /api/v1/state` return the **exact same** `Presenter.state_payload/0`. One
  serialization path guarantees the client sees an identical shape from initial fetch and live push.
- The server-side 1s tick is removed. Countdowns/elapsed times are computed client-side from
  `started_at` / `due_at` / `generated_at` via a `useNow()` hook ticking locally once per second.

### Repository / build layout

```
elixir/
  assets/                      # NEW — Vite app root
    package.json  vite.config.ts  tsconfig.json
    tailwind.config.ts  index.html
    src/
      main.tsx  App.tsx                       # bootstrap + React Router
      lib/        socket.ts queryClient.ts api.ts
      types/      contract.ts                 # hand-written wire-contract types
      features/dashboard/  features/projects/ # screens
      components/ui/                          # shadcn/ui generated primitives (do not hand-edit)
    CLAUDE.md  AGENTS.md                       # frontend conventions (deliverable)
  priv/static/app/             # Vite build output (hashed assets + index.html)
```

### Serving and dev workflow

- **Production:** `vite build` → `priv/static/app/`. The endpoint gains `Plug.Static` (serves
  `priv/static/app`, hashed assets with long `cache-control`); `SpaController` returns `index.html`
  for any non-API/non-asset route. Mix aliases `assets.setup` (`npm ci`) and `assets.build`
  (`vite build`) make a release a single command.
- **Dev:** Vite dev server (`:5173`) with HMR, proxying `/api` and `/socket` to Phoenix.
  `check_origin: false` is already set, so the proxied WebSocket works. Phoenix and Vite run in
  parallel.
- **Socket token:** `index.html` carries `<meta name="csrf-token">`; the `phoenix` client passes it
  in `connect()` params. `UserSocket.connect/3` honors it but currently lets connections through.

## Backend Changes

### New socket + Channel (real-time)

- **`SymphonyElixirWeb.UserSocket`** mounted at `/socket` in the endpoint (alongside `/live`, which
  is removed at cutover). `connect/3` reads a token/CSRF from `params` — minimal validation now, but
  this is the seam for future auth.
- **`SymphonyElixirWeb.ObservabilityChannel`**, topic `"observability:dashboard"`:
  - `join/3`: subscribes to the existing PubSub (`ObservabilityPubSub.subscribe/0`) and returns
    `{:ok, %{state: Presenter.state_payload()}, socket}` so the client has the snapshot immediately.
  - `handle_info(:observability_updated, socket)`: fetches a fresh `Presenter.state_payload()` and
    `push(socket, "state", payload)`.
  - The Channel is **read-only push**. On-demand refresh and single-issue detail stay on REST
    (`POST /api/v1/refresh`, `GET /api/v1/:issue`); we do not duplicate those paths over the socket.

**Contract rule:** the Channel must reuse `Presenter.state_payload/0` verbatim. If `rate_limits`
(currently passed through "raw") ever needs JSON normalization, normalize it **once in the Presenter**
so REST and Channel stay identical.

### REST project CRUD (new) — `ProjectController`, scope `/api/v1`

Mirrors today's UI capabilities exactly (no delete):

| Method | Path | Action | Success |
|---|---|---|---|
| GET | `/api/v1/projects` | list (`Storage.list_projects/0`) | 200 |
| GET | `/api/v1/projects/:id` | fetch one (`Storage.get_project!/1`) | 200 / 404 |
| POST | `/api/v1/projects` | create (`Project.changeset` → `Storage.upsert_project/1`) | 201 |
| PUT | `/api/v1/projects/:id` | update (same path; conflict key is `slug`, as today) | 200 |

Project JSON (flat, 1:1 with form fields), via a dedicated `ProjectJSON` view:

```
id, slug,
linear_project_slug, linear_team_key, linear_human_review_state,
github_owner, github_repo, github_base_branch,
config_version, config (opaque map),
inserted_at, updated_at
```

The flat shape is deliberate so React Hook Form maps fields 1:1. The nested
`durable_project_payload` used by the dashboard stays a separate shape for the dashboard view.

### Error contract (extends the existing envelope)

- Keep `%{error: %{code, message}}`.
- For changeset validation add an optional `fields` map:
  `%{error: %{code: "validation_failed", message: "...", fields: %{slug: ["can't be blank"]}}}` →
  **422**. The client maps `fields` onto React Hook Form errors; Yup also validates client-side
  (including that `config` is a valid JSON object before submit).
- HTTP codes used: `200 / 201 / 404 / 405 / 422 / 503`. Other API routes are unchanged.

### Auth / token (minimal, with a seam)

- `UserSocket.connect/3` accepts the CSRF/token param and currently passes connections through
  (trusted env, `check_origin: false` as today).
- The API stays public as today. No auth is built (YAGNI); only the seam (socket connect + optional
  `/api/v1` plug) is left for later.

## Frontend Architecture

### Data layer (core)

- **`lib/queryClient.ts`** — a singleton `QueryClient`.
- **`lib/socket.ts`** — creates the `phoenix` `Socket("/socket", {params: {token}})` (token from the
  `<meta csrf-token>` tag). A `useDashboardChannel()` hook (mounted once, in a provider) joins
  `"observability:dashboard"`:
  - join ack → `queryClient.setQueryData(['dashboard'], reply.state)`
  - `"state"` event → `setQueryData(['dashboard'], payload)`
  - disconnect/rejoin → React Query retains the last snapshot; a fresh snapshot overwrites it on
    rejoin.
- **`lib/api.ts`** — a typed `fetch` wrapper (base `/api/v1`) that parses the `{error:{code,message,
  fields}}` envelope and throws a typed `ApiError`.
- **Query keys:** `['dashboard']` (live snapshot), `['issue', id]`, `['projects']`, `['project', id]`.
- **Dashboard query:** `useQuery(['dashboard'], api.getState, { staleTime: Infinity })` — initial and
  reconnect over REST; live updates via Channel pushes into the cache. Components read **slices** of
  the snapshot through selectors and stay transport-agnostic.
- **Mutations:** `useCreateProject` / `useUpdateProject` → on success `invalidateQueries(['projects'])`
  and navigate.
- **Contract types** in `src/types/contract.ts` — hand-written TypeScript mirrors of the Presenter
  shapes (`StatePayload`, `RunningEntry`, `RetryEntry`, `BlockedEntry`, `Project`, `WorkRun`,
  `Blocker`, `Artifact`, ...). Single client-side source of truth for the contract.

### Routing (React Router v6)

`/` → Dashboard · `/projects` → list · `/projects/new` → form (create) ·
`/projects/:id/edit` → form (edit) · a layout route provides the app shell + nav · 404 → NotFound.

### Screens (1:1 with current LiveView)

| Screen | Components / sections | Data source |
|---|---|---|
| **Dashboard** | hero/status, metric cards (running/retrying/blocked, token totals, runtime), sandbox diagnostics, projects table, rate limits, work runs, artifacts, running sessions, blocked sessions, retry queue, WS connection indicator | selectors over `['dashboard']`; countdowns/elapsed via `useNow()` (local 1s tick) |
| **Projects list** | table (slug, github owner/repo, base branch, linear slug/team, human review state, config_version) + "New" + "Edit" links | `useQuery(['projects'])` |
| **Project form** | RHF + Yup: slug, github_owner/repo/base_branch, linear_*, config_version (numeric), `config` (JSON) | edit preloads `['project', id]`; submit → mutation; `422.fields` → field errors |

### Forms (React Hook Form + Yup)

- A Yup schema per field; `config` is validated client-side as a valid JSON object before submit.
- Yup `resolver` → RHF; after a `422`, map `error.fields` onto RHF `setError` (client/server
  validation parity).
- Use shadcn/ui `Form` components (Field, Label, Message).

### UI / styling

- **Tailwind + shadcn/ui**, leaning as hard as possible on the **default shadcn theme**. Add only
  the primitives needed (Button, Card, Table, Input, Form, Badge, Alert, Toast, Skeleton, Dialog).
- **Do not write a custom component before checking shadcn for an existing one.** `components/ui/*`
  are generated by the shadcn CLI and are not hand-edited.
- Today's `dashboard.css` look (status colors, badges) is reproduced via the Tailwind theme;
  `dashboard.css` is removed at cutover.

### Error handling and states

- A React **Error Boundary** for render errors.
- **API** errors → Toast (shadcn) + inline field errors from `fields`.
- **Channel:** a connection-status banner; on disconnect show "reconnecting…" and keep the last
  snapshot; on rejoin a fresh snapshot replaces it. `state_payload.error` (snapshot
  unavailable/timeout) shows a warning banner while still displaying the last good data.
- **Loading:** shadcn Skeletons on initial load.

## Migration Phases

The spec covers the full replacement; the plan stages it so `main` stays shippable.

- **Phase 0 — Toolchain + shell:** Vite/TS/Tailwind/shadcn in `assets/`; `Plug.Static` +
  `SpaController`; mix aliases (`assets.setup` / `assets.build`); dev proxy; app shell + nav +
  routing skeleton; the frontend `CLAUDE.md` + `AGENTS.md`. React is served temporarily under
  `/app` while LiveView remains the default at `/`.
- **Phase 1 — Dashboard (real-time):** `UserSocket` + `ObservabilityChannel`; `state_payload`
  TypeScript types; Channel → React Query hydration; the full Dashboard screen. Proves
  React-over-WebSocket end to end.
- **Phase 2 — Projects:** REST CRUD `/api/v1/projects`; projects list + project form (RHF/Yup).
- **Phase 3 — Cutover + cleanup:** flip the catch-all to `SpaController`; remove `*_live.ex`,
  `StaticAssetController`, the vendored-JS routes, `dashboard.css`, and `layouts.ex`; drop the
  `phoenix_live_view` dependency; repoint the e2e harness at React; update docs.

## Testing

- **Frontend:** Vitest + React Testing Library for components and hooks (including
  `useDashboardChannel` with a fake channel and a mocked API client).
- **E2E:** extend the **existing Playwright harness** (the repo already produces e2e video proof for
  the dashboard) to drive the React UI — consistent with the project's "video proof" culture.
- **Backend (ExUnit):** `ObservabilityChannel` (join pushes `state`; broadcast → `"state"` push);
  `ProjectController` (CRUD, `422`, `404`); a **parity test** asserting the Channel payload equals
  `GET /api/v1/state`.
- **Type/contract parity:** a golden JSON fixture captured from `state_payload`, shared so a Vitest
  test parses it against the TypeScript contract types.

## Deliverable: frontend `CLAUDE.md` + `AGENTS.md`

Dedicated files in `assets/` documenting: the stack and versions; directory conventions (`features/`,
`components/ui` are generated and not edited by hand); data-layer rules (React Query keys, the
Channel-hydration pattern, no `fetch` in components — use hooks); the forms pattern (RHF + Yup +
server-error mapping); styling rules (Tailwind + shadcn default theme; never write a custom component
without checking shadcn first; no ad-hoc CSS); testing (Vitest + RTL, Playwright e2e); how to run dev
(Vite + Phoenix) and build (`mix assets.build`); and the location of the payload contract.

## Risks / Watch-items

- **`rate_limits` serialization:** confirm it is JSON-safe in `state_payload`; if not, normalize once
  in the Presenter (REST and Channel share that path).
- **`Storage.delete_project/1` does not exist** and is intentionally out of scope; revisit only if a
  delete affordance is later required.
- **Bandit `server: false`:** the HTTP server is started outside the endpoint
  (`http_server.ex`); adding `Plug.Static` to the endpoint must be verified against that startup path.
- **Coexistence routing:** during Phases 0–2 React lives under `/app`; the catch-all must not shadow
  LiveView routes until the Phase 3 cutover.
