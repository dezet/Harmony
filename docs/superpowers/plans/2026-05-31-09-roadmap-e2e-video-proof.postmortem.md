# Roadmap E2E Video Proof Post Mortem And Handoff

Date: 2026-05-31

Related files:

- `docs/superpowers/plans/2026-05-31-09-roadmap-e2e-video-proof.md`
- `docs/superpowers/plans/2026-05-31-09-roadmap-e2e-video-proof.tasks.md`
- `docs/evidence/roadmap-e2e/`

Active goal:

```text
Verify the repaired Harmony roadmap with deterministic local runtime flows, browser/API proof, and recorded Playwright/Chrome DevTools evidence for every release-blocking milestone.
```

## Post-V2 Status As Of 2026-06-01

The v1 evidence failure described below has been corrected. The final tracked
release evidence is the v2 video set and matching JSON sidecars under
`docs/evidence/roadmap-e2e/`.

- `docs/evidence/roadmap-e2e/milestone-01-workrun-pr-observation-v2.webm`
- `docs/evidence/roadmap-e2e/milestone-02-dedupe-blockers-events-v2.webm`
- `docs/evidence/roadmap-e2e/milestone-03-implementation-handoff-v2.webm`
- `docs/evidence/roadmap-e2e/milestone-04-browser-evidence-gate-v2.webm`
- `docs/evidence/roadmap-e2e/milestone-05-failed-ci-context-v2.webm`

The matching sidecars record `video_revision: 2` and
`proof_style: "feature-specific-live-api-overlay"`. The final browser review
summary is `docs/evidence/roadmap-e2e/final-review-checks.md`.

Fresh post-v2 gates were recorded in the task tracker on 2026-05-31:

- `git diff --check`
- `mix format --check-formatted`
- `mix specs.check`
- `mix test --seed 0`
- `make all`

Remaining open item: independent review did not complete because the subagent
failed with a revoked refresh-token error. No repo-recorded post-v2 systemd host
rollout proof was found for operations hardening.

## User Observation

The first four recorded videos look too similar. They mostly show the same dashboard, projects page, and API state pages. It is not clear from the video itself which milestone is being tested, what feature is under proof, or which runtime values confirm the milestone.

This is a valid release-evidence failure. The JSON sidecars and API assertions contain useful data, but the video artifacts do not independently demonstrate the milestone-specific behavior in a way a reviewer can inspect.

Historical conclusion before the v2 correction:

- Treat existing milestone videos as v1 working artifacts, not final release evidence.
- Do not use the first four v1 videos as proof that the roadmap is verified.
- Regenerate milestone videos as v2 with visible, feature-specific assertions in the frame.

## Current Work State

Implemented or prepared in the current worktree:

- Local Postgres support:
  - `elixir/docker-compose.yml`
  - `elixir/priv/docker/postgres/init/01-create-test-db.sql`
  - `elixir/README.md` updates
- Deterministic scenario harness:
  - `elixir/lib/mix/tasks/harmony.roadmap_e2e.ex`
  - `elixir/lib/symphony_elixir/roadmap_e2e.ex`
  - `elixir/test/symphony_elixir/roadmap_e2e_harness_test.exs`
- Runtime/dashboard/API support:
  - durable projects, work runs, pull request links, blockers, dedupe keys, work events, and artifacts are exposed under `/api/v1/state`
  - dashboard has durable Work runs and Evidence sections
- Existing v1 evidence:
  - `docs/evidence/roadmap-e2e/milestone-01-workrun-pr-observation.webm`
  - `docs/evidence/roadmap-e2e/milestone-02-dedupe-blockers-events.webm`
  - `docs/evidence/roadmap-e2e/milestone-03-implementation-handoff.webm`
  - `docs/evidence/roadmap-e2e/milestone-04-browser-evidence-gate.webm`
  - `docs/evidence/roadmap-e2e/milestone-05-failed-ci-context.webm`
  - sidecar JSON files for milestones 1-5
  - Chrome DevTools Protocol screenshots/logs as fallback because ChromeDevTools MCP was headful without DISPLAY

Important fix already made:

- `mix harmony.roadmap_e2e` now installs runtime guards before `app.start`.
- The task clears configured work source fetchers so local proof cannot accidentally poll live Linear/GitHub sources.
- There is harness test coverage proving the task overrides injected source fetchers.

Known environment state:

- `podman-compose` is installed.
- local Postgres container `harmony-postgres` has been used for `harmony_dev` and `harmony_test`.
- Google Chrome stable is installed at `/opt/google/chrome/chrome`.
- Playwright video recording works.
- At the start of this handoff correction, no `harmony.roadmap_e2e`, `mix test --cover`, `make all`, or matching Chrome remote-debugging process was visible via `pgrep`.

## Verification State

Historical pre-v2 verification is superseded by the post-v2 gate recorded in
`docs/superpowers/plans/2026-05-31-09-roadmap-e2e-video-proof.tasks.md`.

Do not treat independent review as complete:

- The independent review request failed because the subagent auth token could not be refreshed.
- Release-blocking findings, if any, still require a successful independent review or explicit documentation.

## Required V2 Video Evidence

Each v2 video must visibly answer:

- Which milestone is under test?
- Which runtime scenario generated the data?
- Which exact API/dashboard values prove the behavior?
- Which negative assertions are confirmed, if any?
- Which artifact files and sidecars back the recording?

Recommended approach:

- Keep the deterministic runtime scenarios.
- During Playwright recording, navigate to the real dashboard/API pages.
- Inject or render a temporary proof overlay in the browser from live `/api/v1/state` data.
- The overlay should show milestone-specific assertions with exact values from the runtime, not static prose.
- Save the updated video either over the existing `.webm` path or as `*-v2.webm`.
- Update sidecar JSON with `video_revision: 2`, `proof_style: "feature-specific-live-api-overlay"`, and paths to the v2 videos.
- Update the task tracker so v1 is explicitly superseded.

### Milestone 1 V2: Durable WorkRun And PR Observation

The video must show:

- project slug `roadmap-e2e`
- implementation work run persisted in Postgres
- `payload.project_id` equals the durable project id
- work run has `storage_work_run_id` or the persisted work run id is used by the dispatch path
- PR link exists under `pull_request_links`
- PR link points to PR 17, head `cod-101-roadmap-e2e`, base `develop`
- Linear issue `COD-101` is connected to the PR link

The video should not rely on the viewer opening the JSON sidecar to understand the proof.

### Milestone 2 V2: Restart-Safe Dedupe, Blockers, Events

The video must show:

- unsafe failed-CI work run has status `blocked`
- dedupe key has status `blocked`
- open blocker reason is `unsafe_failed_ci_repair`
- `github_comment_created` and `linear_comment_created` work events exist
- restart simulation counts remain unchanged after the second poll
- no duplicate blocker/comment/dispatch is created after restart simulation

The recording should explicitly show before/after counts or a proof panel derived from `/api/v1/state`.

### Milestone 3 V2: Runtime Handoff For Linear Issue Workflow

The video must show two separate paths:

- success path:
  - valid PR link exists
  - runtime emits `linear_state_updated`
  - target state is `Human Review`
- blocker path:
  - missing PR link creates `missing_pull_request_link` blocker
  - Linear comment/blocker path is visible
- negative assertions:
  - no Linear `Done` state is set
  - no PR merge action is performed

The two paths should be visually distinct in the recording.

### Milestone 4 V2: Browser Evidence Runtime Gate

The video must show:

- frontend work run requires `browser` evidence
- missing evidence creates `missing_required_evidence:browser`
- valid screenshot/report/trace artifact allows the gate path covered by tests
- durable artifact metadata is persisted with `work_run_id`
- dashboard Evidence section renders artifact kind/path
- desktop and mobile views both render without overlap/truncation

The dashboard Evidence section should be in the frame long enough to inspect the artifact row.

### Milestone 5 V2: Failed CI Logs And Repair Context

The v1 video for milestone 5 is more distinct than the first four, but regenerate it for consistency if time allows.

The video must show:

- failed GitHub Actions run creates a `ci_fix` work run
- payload includes `workflow_run`
- payload includes `log_excerpt`
- log fetch error path records `log_fetch_error`
- unknown/non-GitHub-Actions checks do not create repair work

## Suggested Next-Session Runbook

1. Re-check current processes and cleanly stop stale runtimes if any are present.
2. Start local Postgres with `podman-compose` if it is not already running.
3. Run targeted harness tests before recording:

   ```sh
   cd elixir
   mix test test/symphony_elixir/roadmap_e2e_harness_test.exs --seed 0
   ```

4. Record v2 videos milestone by milestone.
5. For each video:
   - start the matching `mix harmony.roadmap_e2e` scenario on a known port
   - open `/projects`, `/`, and `/api/v1/state`
   - show a feature-specific proof overlay generated from live API state
   - capture Playwright video
   - capture Chrome DevTools Protocol screenshots/logs if MCP remains headless-blocked
   - update sidecar JSON
   - stop the runtime
6. Update `docs/superpowers/plans/2026-05-31-09-roadmap-e2e-video-proof.tasks.md`.
7. Rerun final verification:

   ```sh
   git diff --check
   cd elixir
   mix format --check-formatted
   mix specs.check
   mix test --seed 0
   make all
   ```

8. Retry independent review only after the auth issue is fixed.

## Acceptance Criteria For The Next Session

The video proof work is acceptable only when:

- a reviewer can identify the milestone from the video alone
- the video shows exact current runtime/API values for that milestone
- each milestone video looks materially different because it proves a different behavior
- sidecars match the recorded video and runtime state
- v1 videos are either superseded in metadata or replaced
- final quality gates have fresh passing output after the evidence update
- remaining independent-review blocker is either resolved or explicitly documented as external auth work
