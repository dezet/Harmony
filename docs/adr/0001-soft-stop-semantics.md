# 0001 — Operator "stop run" is a soft stop

**Status:** Accepted (implemented in Phase 5, 2026-06-13)

## Context

Phase 5 added an operator-initiated "Stop run" action (`POST /api/v1/runs/:identifier/stop` →
`Orchestrator.stop_run/1`). The intuitive expectation is "kill the agent now." Two facts make a
guaranteed hard kill infeasible:

1. **BEAM cannot guarantee OS-subprocess death.** A run is an Elixir `Task` wrapping a long-running
   Codex CLI subprocess. `Task.Supervisor.terminate_child` sends `:shutdown` to the Task; the BEAM
   does not propagate that to the underlying OS process. The CLI can keep running detached until it
   exhausts context or times out.
2. **Workers may be remote.** Agents can run on a remote worker host over SSH. The web/orchestrator
   node has no direct signal path to a process on another machine without extra plumbing.

Separately, Harmony's architecture (per `SPEC.md`) is a *scheduler/runner and tracker reader*: it
deliberately does **not** write to the issue tracker. Ticket state transitions are the agent's job.
That means the orchestrator cannot "end the work" by moving the Linear issue out of an active state —
and on the next poll tick, an issue still in an active tracker state is eligible for dispatch again.

## Decision

"Stop run" is a **soft stop**. On stop the orchestrator:

- terminates the Elixir task tracking the run (frees the concurrency slot),
- removes the run from `running`/`blocked`/`retry_attempts`, adds it to `completed`,
- broadcasts `status_changed → "stopped"` and persists `"stopped"` to the work run when a
  `storage_work_run_id` is known,
- does **not** attempt to kill the underlying OS subprocess, and does **not** write to the tracker.

The UI copy states this honestly: stopping "stops the current attempt and frees the slot; the agent
may finish its in-flight turn, and if the tracker issue is still active it can be re-dispatched on a
later poll." `completed` guards the immediate call, not future poll cycles.

## Consequences

- **Easier:** the action is safe, immediate, and architecture-consistent — no risky cross-host
  process signalling, no tracker writes that violate the runner/reader boundary.
- **Harder / residual:** an operator who wants the work to truly cease must move the tracker issue
  out of an active state (the normal way work ends in Harmony). A stopped run whose issue stays
  active will be picked up again — by design, surfaced in the UI copy, not hidden.

## Alternatives considered

- **Hard kill (track OS PID, signal the process group, handle SSH-remote).** Rejected: partially
  infeasible (remote workers), platform-specific, and high-risk for a feature whose value is
  "free the slot now." Can be revisited if operators hit a concrete need; would be its own ADR.
- **Stop also moves the tracker issue out of active state.** Rejected: violates the
  scheduler/runner-not-ticket-writer boundary that the whole system is built on.
