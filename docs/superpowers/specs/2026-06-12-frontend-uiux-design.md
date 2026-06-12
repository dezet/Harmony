# Harmony Frontend UI/UX Design

## Purpose

This document defines the target information architecture, screens, frontend architecture, and the
API/channel contract work required to evolve the React SPA from a single dashboard dump into a
full operator product. It builds on the completed React + WebSockets cutover
(`2026-06-02-react-websockets-frontend-design.md`, archived).

## Context and Constraints

- **Primary users:** a small team managing agent work per project (review evidence, hand off PRs).
  Secondary mode: actively debugging a single run (timeline, logs, tokens, artifacts).
- **Control surface:** observability plus basic safe actions — refresh/poll now, stop a run,
  retry now. No project lifecycle control (pause, concurrency editing, manual dispatch) in this
  design.
- **Design scale:** several to a dozen projects, dozens of concurrent runs, thousands of historic
  work runs. Tables need filtering, sorting, and pagination; per-project views are first-class.
- **Stack stays:** Vite, React 19, TypeScript, Tailwind v4, shadcn/base-nova, TanStack Query,
  Phoenix Channels. The SPA remains served from `/` by the Elixir backend.
- **Visual direction:** "Studio" — light by default with a dark-mode toggle (theme tokens already
  exist in `src/index.css`), white cards, soft status badges, monospace for identifiers and
  numbers. Linear/Vercel-dashboard feel.

## Information Architecture

Navigation model: **project-first**. The sidebar lists projects; a project is a place, not a
filter. A global overview page compensates for the weaker cross-system view.

### Sidebar (persistent, left)

- Top: **Overview** link.
- Middle: **project list**, each row showing a health dot and active-run count:
  - 🟢 healthy (no retries/blocked), 🟡 retries pending, 🔴 blocked or erroring, ⚪ idle.
- Bottom: **Runtime** link (sandbox posture, rate limits), connection status badge
  (live / reconnecting / offline), dark-mode toggle.

### Routes

| Route | Screen |
| --- | --- |
| `/` | Overview |
| `/projects/:slug` | Project workspace (tabs: Work, Evidence, Activity, Configuration) |
| `/projects/:slug/runs/:identifier` | Run detail |
| `/runtime` | Runtime & rate limits |
| `*` | Designed 404 page |

Header shows a `project / run` breadcrumb on nested routes. All screens deep-link.

### Overview (`/`)

- Metric strip: running / retrying / blocked counts, token totals.
- **Needs attention** section: blocked runs, retries carrying errors, sandbox warnings — each row
  links directly to the run detail.
- Project health grid: card per project with health dot, active counts, last activity.
- Recent cross-project activity feed (compact).

Data source: the existing `observability:dashboard` state payload. This page requires no new
backend work.

### Project workspace (`/projects/:slug`)

Four tabs:

1. **Work** (default). Three columns: *Running*, *Retry + Blocked*, *→ Human Review* (PR links
   with CI status). Below: paginated work-run history table (filter by status/type, sortable).
2. **Evidence.** Artifacts (walkthrough videos, complexity reports, screenshots) grouped by work
   run / PR — the proof-of-work review surface.
3. **Activity.** Chronological feed of the project's `work_events`.
4. **Configuration.** The structured form (current fields) plus a syntax-highlighted, validating
   JSON editor (CodeMirror) for the free-form `config` object, replacing the bare textarea.
   `config_version` stays visible.

### Run detail (`/projects/:slug/runs/:identifier`)

Two columns:

- **Left (~2/3): unified chronological stream** — agent events (`session_started`,
  `turn_completed`, notifications, approvals) interleaved with log entries. Filters: all /
  events only / logs only, plus text search. Live runs append in real time from the run channel.
- **Right (sticky rail):** status + turn count, **Stop** and **Retry now** actions (with confirm
  dialog), per-turn token sparkline, PR links with CI status, artifact list, workspace path,
  attempt history.

The same layout serves live and historical runs; the rail and stream simply stop updating when
the run is terminal.

## Frontend Architecture

### Shared components (new)

- `DataTable` — TanStack Table wrapper providing sorting, filtering, and pagination once, for all
  list views.
- `StatusBadge`, `Timeline`, `LogViewer` (virtualized), `TokensSparkline`,
  `JsonEditor`/`JsonViewer` (CodeMirror), `EmptyState`, `ConfirmDialog`, `ElapsedTime`.

### Structure

- Feature folders following the existing convention: `features/overview`, `features/project`
  (work / evidence / activity / config), `features/run`.
- Existing dashboard components are reshuffled into these features; tables migrate to `DataTable`.

### Fixes to current behavior

- **`useNow` re-render:** the 1 s clock moves into the `<ElapsedTime>` leaf component so ticking
  no longer re-renders whole pages.
- **Theme toggle:** wire the existing dark tokens to a visible toggle (class strategy on `<html>`).
- **404 page:** replace the bare fallback with a designed page.

### Data layer

- TanStack Query remains the cache. Channel pushes hydrate caches as today for the dashboard
  payload; the new run channel applies **granular cache updates** (append event, patch status,
  patch tokens) instead of replacing whole payloads.
- New query keys: `["project-summary", slug]`, `["work-runs", slug, filters]`,
  `["run", identifier]`, `["run-stream", identifier]`, `["artifact", id]`.

## API and Channel Contract (backend work)

The current `state` blob cannot support detail views. Required additions:

### REST (`/api/v1`)

| Endpoint | Purpose |
| --- | --- |
| `GET /projects/:id/summary` | Per-project counts and health for sidebar/workspace header |
| `GET /work_runs?project=&status=&cursor=` | Paginated work-run history |
| `GET /runs/:identifier` | Run detail per SPEC §13.7.2: attempts, recent events, artifacts, PR links, log refs |
| `GET /runs/:identifier/stream?cursor=` | Unified, cursored stream of events + log entries |
| `GET /artifacts/:id` | Artifact content / download |
| `POST /runs/:identifier/stop` | Stop a running session |
| `POST /runs/:identifier/retry` | Fire a queued retry immediately |

- All errors use the existing envelope `{"error": {"code": "...", "message": "..."}}`.
- Action endpoints return the resulting run status; unknown identifiers return 404
  (`issue_not_found`).

### Channels

- `observability:dashboard` **stays as-is** (full state payload). It feeds Overview and the
  sidebar cheaply at this scale.
- New topic **`observability:run:<issue_id>`** with granular events: `event_appended`,
  `status_changed`, `tokens_updated`. Subscribed only while a run detail screen is open. This
  avoids whole-state broadcasts for the high-frequency run view.
- The run detail screen first loads `GET /runs/:identifier`, takes `issue_id` from the response,
  and then joins the topic — REST is addressed by human identifier, channels by stable ID.

## Edge Cases and Error Handling

- Loading skeleton and an error state with a retry button **per section**, not per page.
- Offline banner with automatic reconnect; the connection badge stays in the sidebar.
- Designed empty states: fresh project (no runs yet), no evidence, no activity.
- Stop/Retry actions show a pending state and resolve to a toast; **no optimistic updates** — the
  backend remains the source of truth.
- Action conflicts (e.g. stopping an already-finished run) surface the backend error code in the
  toast.

## Testing

- **Contract fixtures** shared backend↔frontend for every new endpoint and channel event,
  following the existing `state_payload.fixture.json` pattern (Elixir tests assert the fixture
  shape; Vitest tests consume the same file).
- Vitest component tests for new screens and shared components.
- Browser e2e (existing harness) for: Overview → project → run detail navigation, and the
  Stop/Retry action flow.
- Elixir channel tests for `observability:run:*` join/broadcast behavior.

## Phasing

Each phase ends with a working, useful application:

1. **Shell + Overview** — sidebar, theme toggle, breadcrumbs, 404, new Overview page. Runs
   entirely on the existing `/state` payload; no backend changes.
2. **Contract + Work tab** — `work_runs` pagination and `projects/:id/summary` endpoints; project
   workspace with the Work tab and history table; `DataTable`.
3. **Run detail** — `runs/:identifier` + `stream` endpoints, `observability:run:*` channel,
   two-column run detail screen.
4. **Evidence + Activity + Configuration** — artifact content endpoint and Evidence tab, Activity
   feed, CodeMirror config editor.
5. **Actions + Runtime + polish** — stop/retry endpoints and UI actions, Runtime page (sandbox,
   rate limits rendered properly instead of a JSON dump), accessibility pass, empty states.

## Out of Scope

- Project lifecycle control (pause, concurrency limits from UI, manual dispatch).
- Authentication/multi-tenancy.
- Replacing the dashboard channel's full-state broadcast (revisit if scale demands it).
- Live log streaming transport beyond the cursored stream endpoint + run channel events.
