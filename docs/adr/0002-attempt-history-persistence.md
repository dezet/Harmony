# 0002 — Persist run attempts in a dedicated table

**Status:** Proposed (Phase 6)

## Context

The run-detail rail should show an **attempt history** — each attempt's start, end, outcome, and
error. Today the orchestrator tracks attempts only **in memory**: `running_entry.retry_attempt`
(0-indexed current attempt) and `retry_attempts[issue_id].attempt` (the next scheduled attempt).
`Presenter.run_detail_payload` exposes only `{restart_count, current_retry_attempt}` and only when a
live retry entry exists. Nothing is durable: a finished run, or a restart, loses all attempt history.

The orchestrator already has clean lifecycle hook points:

- **Start** — `do_dispatch_issue` / `spawn_issue_on_worker_host` (a `running` entry is created with
  `started_at`, `retry_attempt`, `storage_work_run_id`).
- **End** — the `{:DOWN, …}` handler (`handle_agent_down`), the blocked transition
  (`block_issue_from_entry`), `complete_issue`, and the Phase 5 `stop_run` path — each has the
  identifier, the error/outcome, and the running entry in scope.

Durable persistence patterns already exist: `work_events` (workflow-level events), the `blockers`
table, and the migration convention under `priv/repo/migrations`.

## Decision

Add a dedicated **`run_attempts`** table — one row per attempt — rather than overloading
`work_events`.

Columns: `id`, `project_id`, `work_run_id`, `issue_id`, `identifier`, `attempt_number`,
`started_at`, `ended_at` (null while running), `outcome` (`succeeded | failed | timed_out | stalled |
canceled | stopped | blocked | unknown`), `error` (nullable), `session_id` (nullable), a token
snapshot (`input_tokens`/`output_tokens`/`total_tokens`), `worker_host`, `inserted_at`.

The orchestrator inserts an **open** row at attempt start (storing the row id on the running entry)
and **closes** it (`ended_at`, `outcome`, `error`, token snapshot) at each end hook.
`Presenter.run_detail_payload` gains an `attempts.history: [...]` array (ordered, newest first);
`Storage.list_attempts_for_run/1` backs it. A startup sweep marks any still-open row from a previous
boot as `outcome: "unknown"`, `ended_at: now` so the history never shows a phantom-running attempt.

## Consequences

- **Easier:** attempt history survives restarts; the rail timeline is a straight read; outcomes are
  queryable (e.g. "how often does this project's CI-fix fail twice").
- **Harder / residual:** two extra writes per attempt on the orchestrator path (one insert at start,
  one update at end) — low frequency vs. codex events, acceptable. The startup sweep is required to
  avoid stale open rows. The `outcome` vocabulary must be mapped from the existing terminal reasons.

## Alternatives considered

- **`work_events` rows with `type: "attempt_started"|"attempt_ended"`.** Rejected: mixes a
  first-class lifecycle entity into the opaque workflow-event stream, needs two rows reassembled to
  reconstruct one attempt, and pollutes the existing `list_work_events_for_run` pagination that the
  run stream already serves.
- **In-memory only (status quo).** Rejected: lost on restart, no history, can't answer "what
  happened on attempt 2."
