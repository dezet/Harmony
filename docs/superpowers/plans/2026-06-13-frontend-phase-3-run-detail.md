# Frontend Phase 3: Run Detail + Per-Run Channel Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Two-column run detail screen at `/projects/:slug/runs/:identifier` fed by new `runs/:identifier` + `runs/:identifier/stream` endpoints and a granular `observability:run:<issue_id>` channel, per Phase 3 of `docs/superpowers/specs/2026-06-12-frontend-uiux-design.md`.

**Architecture:** REST detail merges the live orchestrator entry with the durable WorkRun row (artifacts, PR links, work_events). A new per-run PubSub + channel publishes `event_appended` / `status_changed` / `tokens_updated` from three existing orchestrator notify points; the frontend applies them as targeted query-cache patches (no payload replacement). Stream = cursored durable `work_events` ascending + live items appended via channel.

**Honest fallbacks (codebase reality — documented divergences from the spec's ideal):**
- The orchestrator keeps only the LAST agent event per run (no ring buffer) and no per-turn token history; the rail shows token **totals** (sparkline deferred until per-turn data exists).
- No log-serving layer exists (`logs.codex_session_logs` is hardcoded `[]`); the stream serves work_events + live channel items only. The "logs" filter tab is omitted in Phase 3.
- Historical WorkRuns may have `linear_issue_id: nil` → channel join skipped, static view.

**Locked decisions:**
1. New `/api/v1/runs/:identifier` + `/api/v1/runs/:identifier/stream` routes (before the `:issue_identifier` catch-all); existing `GET /api/v1/:issue_identifier` stays untouched.
2. Resolution: durable row via new `get_work_run_by_linear_identifier/1` (most recent match) + live entry from the snapshot by identifier; merged (live status wins). Live-only → empty durable lists; durable-only → static; neither → 404 `run_not_found`.
3. REST addressed by `identifier`, channel topic by `issue_id` (from the REST response; `issue_id: string | null` in the contract).
4. Stream items: `{id, kind: "work_event" | "live_event", type, at, payload}`; ascending by time; cursor = base64url `{"inserted_at","id"}` (same technique as work_runs, but ascending `>` comparison); `meta: {next_cursor, has_live}`.
5. Channel payload shapes (verbatim from the blueprint): `status_changed {issue_id, identifier, status, last_error, at}`, `event_appended {issue_id, identifier, item}`, `tokens_updated {issue_id, identifier, tokens, turn_count, at}`.
6. Orchestrator hooks: exactly three one-line broadcast calls adjacent to existing `notify_dashboard()` sites — codex_worker_update (event_appended + tokens_updated), block path (status_changed), retry scheduling (status_changed). No orchestrator logic changes.
7. Cache strategy: `setQueryData` patches only — append stream item to last page; patch status/last_error/last_event_at; patch tokens/turn_count. Never `invalidateQueries` from channel events.
8. Entry points: identifiers across the app become links to run detail — Work tab columns + history table (slug known from page), Overview NeedsAttention + ActiveRuns rows (slug from the entry's `project.slug`; no link when slug missing).
9. Stop/Retry buttons render in the rail as disabled placeholders ("available soon") — wired in Phase 5.

**Response/channel shapes:** as specified in the blueprint section of this plan's source review; fixtures `run_detail.fixture.json` and `run_stream_page.fixture.json` are the canonical contract (backend key-set tests + frontend type assertions, same pattern as Phase 2).

`RunDetail`: `{identifier, issue_id, work_run_id, status, project {id,slug,name}, workspace {path,host}, session_id, turn_count, started_at, last_event_at, last_event, last_message, tokens {input,output,total}, attempts {restart_count, current_retry_attempt}, pull_requests [HumanReviewPR-shaped], artifacts [{id,kind,path,metadata}], last_error, stream_cursor}` (nullables modeled honestly).

`StreamPage`: `{items: [{id, kind, type, at, payload}], meta: {next_cursor, has_live}}`.

## Tasks

Gates per task: backend `mise exec -- mix test`; frontend `npm run test -- --run && npm run typecheck && npm run lint`. TDD throughout. Conventional commits + AI footer.

### Task A: Storage — run lookup + work-event stream queries
`get_work_run_by_linear_identifier/1` (most recent by inserted_at), `list_work_events_for_run/2` (work_run_id, opts: cursor/page_size; ascending `inserted_at, id`; overfetch +1), `encode_work_event_cursor/1`/`decode_work_event_cursor/1`. Tests mirror the Phase 2 storage tests (deterministic timestamps via `Repo.update_all`).

### Task B: Presenter — `run_detail_payload` + `run_stream_payload`
Pure functions taking pre-fetched inputs (work_run | nil, snapshot, pr_links, artifacts, events page). Live entry located in snapshot by identifier across running/retrying/blocked (status accordingly; durable status as fallback; `status` vocabulary: running/retrying/blocked/then durable status verbatim). `attempts` from live entry fields if present else nulls. Unit tests incl. live-only / durable-only / merged / neither (caller handles 404, presenter never sees nil+nil).

### Task C: REST endpoints + fixtures
`RunDetailController` (`show`, `stream`) + routes + 405 guards before the catch-all; 404 envelope `run_not_found`. Controller fetches: durable row, snapshot (same orchestrator access pattern as ProjectSummaryController), PR links scoped to the run's identifier (filter project PR links by `linear_identifier == identifier`), artifacts via work_run_id (add a Storage query if missing — check schema first), first events page. Tests: 404; live-only; durable-only; merged; stream pagination (2 pages, ascending, no overlap); `has_live` flag both ways; fixture key-set tests for BOTH fixtures.

### Task D: Per-run PubSub + RunChannel
`ObservabilityRunPubSub` (subscribe/broadcast helpers, topic `observability:run:<issue_id>`), `RunChannel` (join subscribes; `handle_info` pushes the three events), `user_socket.ex` registration. Channel tests: join, each broadcast type pushed verbatim, leave unsubscribes (process death).

### Task E: Orchestrator broadcast hooks
Three one-line call sites per Locked decision 6 (find the exact functions: codex_worker_update handler, the blocked transition, retry scheduling — adjacent to existing `notify_dashboard()` calls). Build payloads via a small helper in `ObservabilityRunPubSub` (don't inline map literals in the orchestrator). Verify with a channel-level integration test (drive a fake update through the orchestrator if the existing test harness supports it; else assert PubSub messages directly). Full `mix test` green.

### Task F: Frontend contract + data layer
Types `RunDetail`, `RunStreamItem`, `RunStreamPage` (+ fixture type-assertions in contract.test.ts); `api.ts` `getRunDetail`/`getRunStream`; `queryClient.ts` `RUN_KEY`/`RUN_STREAM_KEY`; `useRunDetail` (staleTime 30s), `useRunStream` (useInfiniteQuery, inference-typed like useWorkRuns — NO explicit generic overrides); api.test.ts coverage.

### Task G: `useRunChannel`
Hook `(issueId: string | null, identifier: string)`: joins `observability:run:<issueId>` on the shared socket (reuse/extract the socket from `src/lib/socket.ts` — extract a `getSocket()` if the dashboard hook owns it privately; keep one socket per app), handlers per Locked decision 7, cleanup leaves the channel. Unit tests with a mocked phoenix Channel/Socket (mirror `socket.test.ts` style): each event patches the right cache key; join skipped when issueId null.

### Task H: Stream + rail components
`StreamItemRow` (icon by kind/type, mono timestamp, type label, payload summary — `payload.message` when string, else compact JSON), `RunStream` (props items/isLoading/error/onLoadMore/hasNextPage; filter tabs All / Events only when both kinds present — omit logs tab; newest at the BOTTOM, auto-scroll only when already at bottom), `RunRail` (status StatusBadge + ElapsedTime since started_at, turn_count, token totals block, PR links (reuse the HumanReviewColumn link pattern), artifacts list (kind + path text), workspace path mono, attempts, disabled Stop/Retry placeholder buttons with title="Available soon"). Component tests from fixtures (empty states included).

### Task I: RunDetailPage + routing + entry links
Page: params slug+identifier; `useRunDetail` → skeleton / 404 state / error+retry; two-column `lg:grid-cols-[1fr_320px]`; left `RunStream` on `useRunStream` (+ channel-appended items), right sticky `RunRail`; `useRunChannel(detail?.issue_id ?? null, identifier)`. Route `projects/:slug/runs/:identifier` in App.tsx. `crumbsFor` → `[Overview, Projects, slug, identifier]` + test. Entry links per Locked decision 8: RunningColumn/RetryBlockedColumn items + WorkRunHistoryTable identifier column (within workspace, slug from props) and Overview ActiveRuns + NeedsAttention (slug from entry project; plain text when absent) — update their tests. Page tests: fixture-driven render, 404, links present.

### Task J: e2e + docs + full gates
e2e: workspace → click a run identifier → run detail renders (breadcrumb, stream item from seeded work_event, rail status). Extend the e2e fixture server with a seeded work run + work_event if needed. CLAUDE.md routing note + `src/features/run/`. Full gates: backend, frontend, build, `mise exec -- make e2e`.

## Out of scope
Stop/Retry actions (Phase 5), log streaming, per-turn token history, Evidence/Activity/Configuration tabs (Phase 4).
