# Phase 6: Durable Run Transcript & Attempt History — Design

**Status:** Draft for review

**Purpose:** Close the two honest gaps left at the end of the frontend rollout
(`2026-06-12-frontend-uiux-design.md`, "Implementation Status"): the run stream's **"logs only"**
filter (no durable transcript today) and a full **attempt-history timeline** (orchestrator tracks
only `restart_count`/`current_retry_attempt`). Both add *debugging depth* to the run-detail screen —
the active-debugger scenario the IA was designed around.

**Decisions of record:** [ADR-0002](../../adr/0002-attempt-history-persistence.md) (dedicated
`run_attempts` table) and [ADR-0003](../../adr/0003-run-transcript-log-capture.md) (capture the
transcript at the orchestrator, not from disk). This spec assumes both.

## Scope

Two coherent capabilities, both extending existing run-detail wiring:

1. **Durable run transcript + real all/events/logs filter.** Persist the agent transcript items
   (today only live-broadcast and lost on reload) so the stream survives reload and the three-way
   filter has data behind it.
2. **Attempt history.** Persist one row per attempt and render a timeline in the run rail.

Out of scope: per-turn token sparkline, hard subprocess kill, serving the app's rotating log file or
worker-host files, log retention/GC policy (a follow-up knob, not this phase).

## Part A — Durable run transcript

### Data

New table `run_transcript_entries`: `id`, `work_run_id` (fk), `project_id` (fk, for scoping),
`kind` (`"event" | "log"`), `type` (string, e.g. `turn_completed`, `notification`), `message`
(string, nullable — the humanized text), `payload` (map, nullable), `session_id` (nullable),
`at`/`inserted_at` (`utc_datetime_usec`). Indexed `(work_run_id, inserted_at, id)` for the ascending
cursor.

### Capture (backend)

At the orchestrator's existing Codex-update hook (`handle_info({:codex_worker_update, …})`, where
`ObservabilityRunPubSub.publish_worker_update` already fires), also persist a transcript row when the
running entry has a `storage_work_run_id`. `kind` is derived from the event type: lifecycle events
(`session_started`, `turn_completed`, `turn_failed`, approvals) → `"event"`; finer output
(`notification`, agent messages) → `"log"`. Persist the **humanized summary** already computed for
the broadcast — not raw token deltas. The live `event_appended` channel push is unchanged (real-time
append); it now simply also has a durable twin.

### Serving (backend)

`Presenter.run_stream_payload` and `Storage.list_work_events_for_run` extend to a **merged** stream:
work_events (kind `"work_event"`) **+** transcript entries (kinds `"event"`/`"log"`), time-ordered,
one cursor over the union. The stream item shape is unchanged (`{id, kind, type, at, payload}`);
`kind` now carries `work_event | event | log`. Cursor stays `(inserted_at, id)` ascending.

### Filtering (frontend)

`RunStream`'s filter becomes the spec's three modes:

- **All** — every item.
- **Events** — `kind ∈ {work_event, event}` (lifecycle + workflow).
- **Logs** — `kind === "log"` (agent transcript output).

The filter buttons render whenever the stream has mixed kinds (today's "show only when both present"
logic generalizes to three). Text search (already shipped) composes with the kind filter. The
existing live append, `aria-live` region, and "load more" are unchanged — items just persist now.

## Part B — Attempt history

### Data

New table `run_attempts` (per ADR-0002): `id`, `project_id`, `work_run_id`, `issue_id`, `identifier`,
`attempt_number`, `started_at`, `ended_at` (null while running), `outcome`
(`succeeded | failed | timed_out | stalled | canceled | stopped | blocked | unknown`), `error`,
`session_id`, `input_tokens`/`output_tokens`/`total_tokens`, `worker_host`, `inserted_at`.

### Lifecycle hooks (backend)

- **Start** (`spawn_issue_on_worker_host`): insert an open row (`ended_at: nil`), store its id on the
  running entry (`attempt_row_id`).
- **End** — close the row (`ended_at`, `outcome`, `error`, token snapshot) at each terminal hook:
  `handle_agent_down` (map the exit reason → outcome), `block_issue_from_entry` (`blocked`),
  `complete_issue` (`succeeded`), Phase 5 `stop_run` (`stopped`), stall/timeout paths.
- **Startup sweep:** at boot, close any row still open from a previous run as `unknown` /
  `ended_at: now` so no phantom-running attempt appears.

These are additive one-liners adjacent to existing state transitions — the same minimal-invasiveness
discipline as the Phase 3 orchestrator broadcast hooks and Phase 5 stop hooks.

### Serving + rendering

`Storage.list_attempts_for_run/1` (ordered newest-first); `Presenter.run_detail_payload` gains
`attempts.history: [{attempt_number, started_at, ended_at, outcome, error, tokens, session_id}]`
alongside the existing `{restart_count, current_retry_attempt}`. The run rail renders a compact
timeline: per attempt a row with number, outcome badge, duration (`ended_at - started_at` or "running"),
and error on failure. Empty/one-attempt runs degrade gracefully (a single "Attempt 1" row).

## API & contract

No new endpoints — both ride existing run-detail wiring:

- `GET /api/v1/runs/:identifier/stream` now returns merged items (new `kind` values `event`/`log`).
- `GET /api/v1/runs/:identifier` gains `attempts.history`.

Contract fixtures `run_stream_page.fixture.json` and `run_detail.fixture.json` are extended (shared
backend↔frontend, per the established pattern) with the new kinds and the history array. Frontend
`RunStreamItem.kind` widens to `"work_event" | "event" | "log"`; `RunDetail.attempts` gains
`history`.

## Edge cases

- **Volume:** transcript rows can be many per session. Persist humanized summaries only; reuse
  existing event throttling. A retention/cap knob is a documented follow-up, not this phase.
- **Live-only runs** (no `storage_work_run_id`): no transcript persistence and no attempt rows —
  the stream shows live items only (today's behavior), and the rail shows the live attempt counter.
  Honest degradation, unchanged from Phase 3.
- **Restart mid-run:** the startup sweep closes orphaned attempt rows; transcript rows already
  persisted remain and reload correctly.
- **Ordering:** transcript and work_events share the `(inserted_at, id)` ascending cursor; ties break
  by id deterministically.

## Testing

- Storage: cursor pagination over the merged stream; `list_attempts_for_run` ordering; startup sweep.
- Orchestrator: a transcript row is written on codex update; an attempt row opens on dispatch and
  closes with the right outcome on each terminal path (down/block/complete/stop) — extend the
  existing orchestrator action/broadcast tests.
- Presenter: merged stream payload (kinds), `attempts.history` shape — pure-function tests.
- Contract fixtures asserted on both sides.
- Frontend: RunStream three-way filter (logs filter now has data); RunRail attempt timeline
  (multi-attempt, single-attempt, running, failed).
- e2e: the fixture server seeds a couple of transcript rows + a two-attempt history; assert the logs
  filter shows transcript output and the rail shows the timeline.

## Build phasing

A natural backend-first order (detailed in the plan): migrations + storage → orchestrator capture &
attempt hooks → presenter merge & history → contract fixtures → frontend filter & timeline → e2e &
docs. Each step independently testable and committable.
