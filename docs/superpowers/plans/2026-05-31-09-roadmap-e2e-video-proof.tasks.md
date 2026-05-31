# Roadmap E2E Video Proof Task Tracker

Source plan: `docs/superpowers/plans/2026-05-31-09-roadmap-e2e-video-proof.md`

Goal-ready objective:

```text
Verify the repaired Harmony roadmap with deterministic local runtime flows, browser/API proof, and recorded Playwright/Chrome DevTools evidence for every release-blocking milestone.
```

## Progress

Post mortem / handoff:

- `docs/superpowers/plans/2026-05-31-09-roadmap-e2e-video-proof.postmortem.md`

Current correction:

- User review found that the first four milestone videos look too similar and do not clearly prove what is being tested.
- Existing v1 videos and sidecars remain useful working artifacts, but they are not final release evidence.
- Next session must regenerate v2 videos with feature-specific proof visible in the recording itself.

- [x] Task 0: Local runtime gate
  - [x] Verify `podman-compose` provider is available.
  - [x] Start local Postgres.
  - [x] Verify `harmony_dev` and `harmony_test`.
  - [x] Run dev/test migrations.
  - [x] Run `mix test --seed 0`.
  - [x] Run `make all`.
- [x] Task 1: Deterministic roadmap scenario harness
  - [x] Add `mix harmony.roadmap_e2e` dev/test scenario task.
  - [x] Support `milestone1`, `milestone2`, `milestone3_success`, `milestone3_blocker`, `milestone4`, and `milestone5`.
  - [x] Ensure scenarios use fake Linear/GitHub sources only.
  - [x] Print runtime URL, project slug, work run ids, dedupe keys, and expected assertions.
  - [x] Add automated harness tests.
- [ ] Task 2: Milestone 1 proof - Durable WorkRun and PR observation
  - [x] Run `milestone1` scenario.
  - [x] Verify Linear implementation `WorkRun` has `payload.project_id`.
  - [x] Verify PR observation persists or updates `pull_request_links`.
  - [x] Record Playwright video over `/projects`, `/`, and `/api/v1/state`.
  - [x] Capture Chrome DevTools console/network/screenshot evidence.
  - [x] Save video and JSON sidecar.
  - [x] Add browser smoke test if the proof is repeatable.
- [x] Task 3: Milestone 2 proof - Restart-safe dedupe, blockers, events
  - [x] Run `milestone2` scenario.
  - [x] Verify durable blocker and `blocked` dedupe state.
  - [x] Verify no agent dispatch occurs for unsafe failed CI.
  - [x] Verify external writes emit `work_events`.
  - [x] Simulate restart or fresh orchestrator state.
  - [x] Verify second poll is suppressed.
  - [x] Record Playwright video and Chrome DevTools evidence.
  - [x] Save video and JSON sidecar.
  - [x] Add browser/API smoke test if the proof is repeatable.
- [x] Task 4: Milestone 3 proof - Runtime handoff for Linear issue workflow
  - [x] Run `milestone3_success` scenario.
  - [x] Verify valid PR link moves Linear target to `Human Review`.
  - [x] Run `milestone3_blocker` scenario.
  - [x] Verify missing PR link records blocker and Linear comment.
  - [x] Verify bad base/head branch policy records blocker.
  - [x] Verify no scenario sets Linear `Done`.
  - [x] Verify no scenario merges PR.
  - [x] Record dashboard/API video and save sidecar.
- [x] Task 5: Milestone 4 proof - Browser evidence runtime gate
  - [x] Run `milestone4` scenario.
  - [x] Verify frontend work without artifacts records blocker.
  - [x] Add valid screenshot/report/trace evidence manifest.
  - [x] Verify artifact metadata persists with `work_run_id`.
  - [x] Verify path traversal artifacts are rejected by automated tests.
  - [x] Record desktop and mobile Evidence section video.
  - [x] Capture Chrome DevTools layout/API evidence.
  - [x] Save video and JSON sidecar.
- [x] Task 6: Milestone 5 proof - Failed CI logs and repair context
  - [x] Run `milestone5` scenario.
  - [x] Verify failed GitHub Actions PR creates `ci_fix` work run.
  - [x] Verify payload includes `workflow_run`, `log_excerpt`, run id, workflow name, and URL.
  - [x] Verify log fetch error records `log_fetch_error` and does not crash polling.
  - [x] Verify unknown/non-GitHub-Actions checks do not trigger repair.
  - [x] Record dashboard/API video and save sidecar.
- [x] Task 7: Final browser review pass
  - [x] Check desktop `/`, `/projects`, `/projects/new`, and `/api/v1/state`.
  - [x] Check mobile `/`, `/projects`, and `/projects/new`.
  - [x] Check Chrome DevTools console and network health.
  - [x] Verify no text overlap/truncation in running, retrying, blocked, and evidence sections.
  - [x] Verify raw config JSON validation errors are readable.
  - [x] Verify sandbox diagnostics are visible.
  - [x] Verify UI does not suggest automerge, Linear `Done`, or automatic production rollout.
  - [x] Save `docs/evidence/roadmap-e2e/final-review-checks.md`.
- [x] Task 8: Video proof v2 correction
  - [x] Regenerate Milestone 1 video with visible Durable WorkRun and PR Observation proof from live runtime/API state.
    - `docs/evidence/roadmap-e2e/milestone-01-workrun-pr-observation-v2.webm`
  - [x] Regenerate Milestone 2 video with visible blocked dedupe, open blocker, work events, and restart-suppression counts.
    - `docs/evidence/roadmap-e2e/milestone-02-dedupe-blockers-events-v2.webm`
  - [x] Regenerate Milestone 3 video with visually distinct success Human Review handoff and blocker paths.
    - `docs/evidence/roadmap-e2e/milestone-03-implementation-handoff-v2.webm`
  - [x] Regenerate Milestone 4 video with visible required browser evidence gate and durable Evidence artifact metadata.
    - `docs/evidence/roadmap-e2e/milestone-04-browser-evidence-gate-v2.webm`
  - [x] Regenerate or explicitly revalidate Milestone 5 video with visible failed-CI workflow/log context proof.
    - `docs/evidence/roadmap-e2e/milestone-05-failed-ci-context-v2.webm`
  - [x] Update milestone sidecar JSON files with `video_revision: 2` and v2 artifact paths.
  - [x] Mark v1 videos as superseded or replace them in place after v2 evidence is recorded.
- [ ] Task 9: Final quality gate and review
  - [x] Run `git diff --check`.
  - [x] Run `mix format --check-formatted`.
  - [x] Run `mix specs.check`.
  - [x] Run `mix test --seed 0`.
  - [x] Run `make all`.
  - [x] Rerun all final gates after Task 8 v2 evidence updates.
  - [ ] Request independent review.
  - [ ] Resolve or document all release-blocking findings.

  Note: independent review request was attempted, but the subagent failed with a revoked refresh-token error before returning findings.
  Fresh post-v2 gates passed on 2026-05-31 after recording v2 evidence:
  `git diff --check`, `mix format --check-formatted`, `mix specs.check`,
  `mix test --seed 0`, and `make all`.
