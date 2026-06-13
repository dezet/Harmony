# Phase 6: Durable Run Transcript & Attempt History — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the run-detail stream's **logs** filter real (durable agent transcript) and add an
**attempt-history timeline** to the rail, per
`docs/superpowers/specs/2026-06-13-phase-6-logs-attempts-design.md`.

**Architecture:** Two new durable tables (`run_transcript_entries`, `run_attempts`) written from
existing orchestrator hooks; the run stream serves a merged work_events + transcript feed; run detail
gains `attempts.history`. No new endpoints — extends Phase 3 wiring. Decisions:
[ADR-0002](../../adr/0002-attempt-history-persistence.md), [ADR-0003](../../adr/0003-run-transcript-log-capture.md).

**Working dirs:** backend from `elixir/` (`mise exec -- mix test`); frontend from `elixir/assets/`
(`npm run test -- --run && npm run typecheck && npm run lint`). TDD throughout; conventional commits
+ AI footer. Each task independently committable.

**Locked decisions:**
1. Two dedicated tables (not `work_events` overload, not in-memory, not log-file parsing).
2. Transcript captured at the orchestrator codex-update hook (the `event_appended` broadcast site),
   humanized summaries only, `kind` ∈ {event, log} by event type.
3. Stream serves a **merged** cursor over work_events (kind `work_event`) + transcript
   (kinds `event`/`log`), `(inserted_at, id)` ascending; item shape unchanged.
4. Attempt rows: open at dispatch (id stored on running entry), close at every terminal hook with a
   mapped `outcome`; startup sweep closes orphans as `unknown`.
5. `attempts.history` added to run detail alongside existing `{restart_count, current_retry_attempt}`.
6. Frontend filter becomes all/events/logs; text search composes; live append unchanged.
7. Contract fixtures extended on both sides (no new endpoints).

## Tasks

### Task A — Migrations + schemas
Two migrations (`priv/repo/migrations`, timestamped per convention) + Ecto schemas:
`RunTranscriptEntry` (`work_run_id`, `project_id`, `kind`, `type`, `message`, `payload`, `session_id`,
`utc_datetime_usec` timestamps; index `(work_run_id, inserted_at, id)`) and `RunAttempt`
(`project_id`, `work_run_id`, `issue_id`, `identifier`, `attempt_number`, `started_at`, `ended_at`,
`outcome`, `error`, `session_id`, token fields, `worker_host`; index `(work_run_id, started_at, id)`).
Changesets with required-field validation. Migration tests / schema tests per repo patterns. Run
`ecto.migrate` for dev+test.

### Task B — Storage queries
`insert_transcript_entry/1`; `list_transcript_entries_for_run/2` (cursor, ascending) — OR fold into a
merged query (see Task C). `insert_run_attempt/1` (returns the row), `close_run_attempt/2` (id + close
attrs), `list_attempts_for_run/1` (desc), `list_open_run_attempts/0` (for the sweep). Reuse the
shared cursor helpers (`encode/decode_*_cursor`, `(inserted_at,id)` keyset). Deterministic-timestamp
tests (the `Repo.update_all` stamping pattern from Phase 2/3 storage tests).

### Task C — Merged stream query + presenter
Decide the merge mechanics: simplest correct is a UNION-style fetch (work_events + transcript) ordered
`(inserted_at, id)` asc with one opaque cursor, overfetch +1. Implement `Storage.list_run_stream_for_run/2`
(or extend `list_work_events_for_run`). Extend `Presenter.run_stream_payload` to emit the merged items
with `kind ∈ {work_event, event, log}`. Add `Presenter` attempt projection: `attempts.history` array
(ordered, with duration-able fields) merged into `run_detail_payload` (keep existing
`restart_count`/`current_retry_attempt`). Pure-function tests for both; verify cursor has no overlap
across the merged set.

### Task D — Orchestrator capture + attempt hooks (additive, critical module)
At `handle_info({:codex_worker_update, …})` (next to `publish_worker_update`): persist a transcript
row when `storage_work_run_id` present, `kind` via a small `transcript_kind(event_type)` helper
(lifecycle → event, else log), message = the humanized summary. Attempt lifecycle: insert open row in
`spawn_issue_on_worker_host` (store `attempt_row_id` on the running entry); close it in
`handle_agent_down` (exit reason → outcome), `block_issue_from_entry` (`blocked`), `complete_issue`
(`succeeded`), `stop_run` (`stopped`), stall/timeout paths. Add a startup sweep
(`list_open_run_attempts` → close as `unknown`) at boot. STRICTLY additive — no existing logic/return
changed; the full orchestrator test suite is the regression net. Extend the orchestrator tests:
transcript row written on update; attempt row opens on dispatch and closes with the correct outcome
per terminal path; sweep closes orphans.

### Task E — Contract fixtures + API tests
Extend `run_stream_page.fixture.json` (items with `kind: "event"` and `"log"` alongside `work_event`)
and `run_detail.fixture.json` (`attempts.history` with a two-attempt example). Update the Elixir
fixture key-set contract tests and the run-detail/stream API tests to cover the merged kinds + history.
Confirm no endpoint signature changes.

### Task F — Frontend contract + stream logs filter
Widen `RunStreamItem.kind` to `"work_event" | "event" | "log"`; add `attempts.history` to `RunDetail`
(+ contract.test.ts fixture assertions). `RunStream`: filter becomes All / Events
(`work_event`+`event`) / Logs (`log`), shown when ≥2 kinds present; compose with existing text search;
keep `aria-live`, `aria-pressed`, load-more. Tests: logs filter now yields rows; events excludes logs;
search composes.

### Task G — Frontend attempt timeline + e2e + docs
`RunRail`: render `detail.attempts.history` as a compact timeline (attempt #, outcome StatusBadge,
duration via existing time helpers, error on failure); graceful single-attempt/running/empty. Tests
(multi-attempt, failed, running). e2e: extend the fixture server to seed a couple of transcript rows
+ a two-attempt history; assert the Logs filter shows transcript output and the rail shows the
timeline. Update CLAUDE.md (transcript/attempt model, the honest "logs = agent transcript" definition).
Move the two items out of the spec's "Implementation Status" deferred list. Full gates: backend,
frontend test+typecheck+lint+build, `mise exec -- make e2e`.

## Out of scope (documented)
Per-turn token sparkline; transcript retention/GC policy (a follow-up knob); hard subprocess kill;
serving the app rotating log or worker-host files.
