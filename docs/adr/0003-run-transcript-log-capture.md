# 0003 — Capture the run transcript at the orchestrator, not from disk

**Status:** Proposed (Phase 6)

## Context

The run-detail spec wants a stream with an **all / events / logs** filter. Today the stream
(`Presenter.run_stream_payload`) serves durable `work_events` (workflow-level: handoffs, comments)
plus **live** channel items (`event_appended`) built from Codex updates. The live items — the actual
agent transcript (turn completions, notifications, messages) — are **broadcast but never persisted**:
on reload they vanish, and there is no "logs" data to filter to.

The obvious "serve the logs" instinct does not work here:

- The only on-disk logs are the **app-wide rotating `log/symphony.log`** (`log_file.ex`): a single
  file, 10 MiB × 5 rotation, no per-session segregation, **no read API**. Parsing it by `issue_id`
  is fragile (rotation drops history, interleaved with all other logs).
- Agents may run on **remote worker hosts**. Any per-session log file written on the worker is not on
  the web/orchestrator node — tailing files off disk breaks for the remote case.

Crucially, the agent **already streams its events back to the orchestrator** — that is exactly what
powers the live channel (`handle_info({:codex_worker_update, …})` → `publish_worker_update`). That
ingestion point is centralized on the web node and sees every transcript item.

## Decision

Capture the run transcript **at the orchestrator's existing event-ingestion point** — where Codex
updates are already handled and `event_appended` is already broadcast — by persisting each item into
a dedicated **`run_transcript_entries`** table (`work_run_id`, `kind` ∈ `event | log`, `type`,
`message`/`payload`, `at`, `session_id`). The run stream then serves a **merge** of `work_events`
(kind `work_event`) and transcript entries (kinds `event`/`log`), time-ordered and cursor-paginated;
the UI's all/events/logs filter maps onto those kinds. Live `event_appended` items keep flowing over
the channel for real-time append, but are now also durable, so reload shows the full transcript.

We do **not** serve the app's rotating log file, and we do **not** tail worker-host files. Raw
protocol dumps / full operator logs remain operator-only (the existing log file), out of scope.

`kind` discrimination: lifecycle items (session_started, turn_completed, turn_failed, approvals) →
`event`; finer textual output (notifications, agent messages, command summaries) → `log`. The
humanized summary the orchestrator already produces is what we persist — not raw token deltas.

## Consequences

- **Easier:** the stream survives reload; the all/events/logs filter becomes real; no remote-host
  file access, no log-file parsing; rides infrastructure that already exists and is centralized.
- **Harder / residual:** transcript volume — chatty sessions write many rows. Mitigations: persist
  humanized summaries (not every token), reuse the existing event throttling, and add a retention/cap
  knob (a follow-up if volume bites). "Logs" here means the **agent transcript**, not raw protocol or
  the app log — an honest, narrower definition that should be stated in the UI.

## Alternatives considered

- **Parse `log/symphony.log` by issue/session.** Rejected: no read API, rotation loses history,
  interleaved with unrelated logs, fragile.
- **Per-session log files + a tailing endpoint with path containment.** Rejected primarily because
  remote workers write those files on a different host; also adds a second security-sensitive
  file-serving surface (cf. the artifact endpoint) for data we already receive in-process.
- **Reuse `work_events`.** Rejected: work_events are coarse workflow events; transcript volume would
  pollute them and their pagination. A dedicated table isolates volume and retention.
