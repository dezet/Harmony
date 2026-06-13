# Harmony Product Ideas

Date: 2026-06-01

## Context

Harmony is now past the initial roadmap foundation. The current repo includes durable storage,
WorkRun/WorkSource, GitHub polling workflows, failed-CI handling, `@hreview`, browser evidence,
project configuration UI, runtime diagnostics, and recorded roadmap evidence under
`docs/evidence/roadmap-e2e/`.

The next useful product work should focus on making the existing automation easier to trust,
inspect, operate, and explain to reviewers.

## 10 Useful User-Facing Features

1. **Run Detail / Timeline**

   Add a dedicated run detail page with a timeline of dispatch, dedupe, PR linkage, agent events,
   blockers, evidence, and handoff state. The router currently exposes dashboard and project
   pages, but no first-class `/runs/:id` view.

2. **Evidence Viewer**

   Turn evidence from a path table into a reviewable artifact experience: image preview,
   `.webm` playback, JSON sidecar view, metadata, and a short explanation of what each artifact
   proves.

3. **Operator Action Center**

   Provide a single workflow for blocker handling: retry, cancel, mark resolved, add note,
   request human input, or requeue. Current blocker state is visible, but not yet an operator
   command surface.

4. **Work Queue Explorer**

   Show why work did or did not run: candidate detected, skipped by dedupe, blocked by policy,
   waiting for retry, missing evidence, no capacity, or inactive tracker state.

5. **PR Command Center**

   Create a unified PR screen covering CI state, review status, `@hreview`, failed-CI repairs,
   Linear links, blockers, evidence, and current handoff status.

6. **Full Logs And Event Search**

   Add searchable logs and events by run, PR, issue, dedupe key, event type, and time range.
   The current per-issue API shape still exposes `codex_session_logs` as an empty list.

7. **Analytics And Cost Dashboard**

   Add historical metrics: success rate, retry rate, blocker reasons, lead time, runtime, token
   usage, estimated cost, and utilization by project or agent backend.

8. **Policy Simulator / Preflight**

   Before dispatch, show whether branch guards, PR-only policy, evidence requirements, sandbox
   posture, GitHub permissions, and Linear state transitions are expected to pass.

9. **Notification Integrations**

   Send Slack, Linear, or GitHub notifications for blocked runs, Human Review handoff, failed
   repair, missing evidence, rate limits, stale runs, and completed review requests.

10. **Real Multi-Agent Backend Execution**

    Finish platform expansion by implementing actual Claude Code and Pi execution backends.
    Today these backends exist as capability probes and explicitly return not-implemented errors.

## Recommended Order

1. Run Detail / Timeline
2. Evidence Viewer
3. Operator Action Center
4. PR Command Center
5. Work Queue Explorer

This order increases user trust and day-to-day operability before investing in additional agent
backends or broader platform expansion.
