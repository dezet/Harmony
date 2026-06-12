# Harmony Roadmap Current Status

Date: 2026-06-03

Branch / PR: `spec/react-websockets-frontend`

This document is the current status index for the roadmap work. It is based on
repo facts: source files, tests, recorded evidence, and the roadmap task
tracker. It does not mark historical implementation-plan checkboxes as source
of truth.

## Summary

- Roadmap e2e proof videos are recorded for the release-blocking proof flows
  M1-M5 under `docs/evidence/roadmap-e2e/`.
- Original roadmap M6 is implemented and is covered by the browser evidence
  proof video `milestone-04-browser-evidence-gate-v2.webm`.
- Original roadmap M7 has implementation/runbook coverage, but no repo-recorded
  post-v2 systemd host rollout proof was found.
- Original roadmap M8 is implemented and verified in the current worktree.
  Claude Code and Pi now have non-interactive CLI execution adapters rather
  than capability-only stubs.
- Independent review remains open because the previous subagent review request
  failed with a revoked refresh-token error.

## Roadmap Status

| Roadmap milestone | Implementation status | Proof status | Concrete references | Remaining gap |
| --- | --- | --- | --- | --- |
| M1 Postgres and project config | Implemented | Covered by tests and e2e M1 durable-state proof | Storage tables: `elixir/priv/repo/migrations/20260531010000_create_harmony_storage.exs:7`; storage context: `elixir/lib/symphony_elixir/storage.ex:11`; YAML sync: `elixir/lib/symphony_elixir/project_config/sync.ex:25`; multi-project sync test: `elixir/test/symphony_elixir/project_config_test.exs:38`; video: `docs/evidence/roadmap-e2e/milestone-01-workrun-pr-observation-v2.webm`. | None known for MVP. |
| M2 Runtime policy and WorkRun | Implemented | Covered by tests and e2e M1/M3 handoff proof | Work run persistence: `elixir/lib/symphony_elixir/storage.ex:91`; durable blockers: `elixir/lib/symphony_elixir/storage.ex:152`; dedupe status: `elixir/lib/symphony_elixir/storage.ex:181`; implementation handoff: `elixir/lib/symphony_elixir/runtime_policy/implementation_handoff.ex:10`; tests: `elixir/test/symphony_elixir/implementation_handoff_test.exs:7`. | Independent review still open. |
| M3 GitHub integration foundation | Implemented | Covered by tests and e2e PR observation proof | PR observation source: `elixir/lib/symphony_elixir/work_sources/github_pr_source.ex:1`; PR link storage: `elixir/lib/symphony_elixir/storage.ex:244`; sidecar: `docs/evidence/roadmap-e2e/milestone-01-workrun-pr-observation.json`. | None known for MVP. |
| M4 Failed CI fix workflow | Implemented | Covered by tests and e2e M2/M5 proof | Failed CI source: `elixir/lib/symphony_elixir/work_sources/github_failed_ci_source.ex:10`; log/error payload: `elixir/lib/symphony_elixir/work_sources/github_failed_ci_source.ex:87`; tests: `elixir/test/symphony_elixir/github_failed_ci_source_test.exs:7`; videos: `milestone-02-dedupe-blockers-events-v2.webm`, `milestone-05-failed-ci-context-v2.webm`. | None known for MVP. |
| M5 `@hreview` workflow | Implemented | Covered by tests; no separate final video beyond final UI/API review | Review request source: `elixir/lib/symphony_elixir/work_sources/github_review_request_source.ex:15`; review handoff: `elixir/lib/symphony_elixir/workflows/review_handoff.ex:11`; inline comments: `elixir/lib/symphony_elixir/workflows/inline_review_comments.ex:21`; trigger test: `elixir/test/symphony_elixir/github_review_request_source_test.exs:7`. | Independent review still open. |
| M6 Browser evidence MVP | Implemented | Covered by e2e M4 browser evidence video | Evidence policy: `elixir/lib/symphony_elixir/evidence/policy.ex:8`; manifest parser and path guard: `elixir/lib/symphony_elixir/evidence/manifest.ex:22`; collector: `elixir/lib/symphony_elixir/evidence/collector.ex:9`; handoff gate: `elixir/lib/symphony_elixir/runtime_policy/handoff.ex:28`; tests: `elixir/test/symphony_elixir/evidence_test.exs:127`; video: `docs/evidence/roadmap-e2e/milestone-04-browser-evidence-gate-v2.webm`. | None known for MVP. |
| M7 Operations hardening | Implemented as tooling and runbook | No repo-recorded post-v2 host rollout proof found | Sandbox diagnostics: `elixir/lib/symphony_elixir/diagnostics/sandbox.ex:26`; API/dashboard projection: `elixir/lib/symphony_elixir_web/presenter.ex:340`; runbook: `docs/harmony-operations.md:55`; installer: `install-harmony-proof-of-life.sh:50`; systemd unit: `harmony.service:1`; tests: `elixir/test/symphony_elixir/diagnostics_test.exs:6`. | Need an explicit recorded/manual host proof if this must be called rollout-complete. |
| M8 Platform expansion | Implemented and verified | Targeted tests and full `make all` pass | Backend resolver: `elixir/lib/symphony_elixir/agent_backend.ex`; Codex adapter: `elixir/lib/symphony_elixir/agent_backends/codex.ex`; Claude Code adapter: `elixir/lib/symphony_elixir/agent_backends/claude_code.ex`; Pi adapter: `elixir/lib/symphony_elixir/agent_backends/pi.ex`; React project UI: `elixir/assets/src/routes/ProjectsPage.tsx`, `elixir/assets/src/routes/ProjectFormPage.tsx`; project API: `elixir/lib/symphony_elixir_web/controllers/project_controller.ex`; webhooks: `elixir/lib/symphony_elixir_web/controllers/github_webhook_controller.ex`; video artifacts: `elixir/test/symphony_elixir/video_evidence_test.exs`; multi-project scheduling test: `elixir/test/symphony_elixir/orchestrator_status_test.exs`. | None known. |
| M9 Roadmap e2e video proof | Mostly complete | V2 videos and sidecars are tracked | Task tracker: `docs/superpowers/plans/2026-05-31-09-roadmap-e2e-video-proof.tasks.md`; final browser review: `docs/evidence/roadmap-e2e/final-review-checks.md`; videos: `docs/evidence/roadmap-e2e/*-v2.webm`. | Independent review and release-blocking findings remain open. |

## Verification Notes

Recorded in the task tracker after v2 evidence generation on 2026-05-31:

- `git diff --check`
- `mix format --check-formatted`
- `mix specs.check`
- `mix test --seed 0`
- `make all`

Fresh targeted status check run during the 2026-06-03 M8 update:

```bash
cd elixir
mix test \
  test/symphony_elixir/evidence_test.exs \
  test/symphony_elixir/video_evidence_test.exs \
  test/symphony_elixir/diagnostics_test.exs \
  test/symphony_elixir/project_api_test.exs \
  test/symphony_elixir/github_webhook_test.exs \
  test/symphony_elixir/inline_review_comments_test.exs \
  test/symphony_elixir/agent_backend_test.exs \
  test/symphony_elixir/project_config_test.exs --seed 0
```

Observed result: `80 tests, 0 failures`.

React targeted verification:

```bash
cd elixir/assets
npm test -- ProjectsPage.test.tsx ProjectFormPage.test.tsx --run
npm run typecheck
npm test -- --run
```

Observed result: route tests `10 tests, 0 failures`; typecheck exited 0; full Vitest
suite `33 tests, 0 failures`.

Full gate:

```bash
cd elixir
make all
```

Observed result: setup/build/assets/format/lint/coverage/dialyzer exited 0;
coverage ran `339 tests, 0 failures, 2 skipped`, total coverage `86.17%`;
Dialyzer reported `Total errors: 0`.

## Evidence Policy

Final review evidence is the v2 set. Local untracked v1 artifacts are working
artifacts only and should not be committed.

Archived-or-current status of older plans has not been rewritten yet. The next
cleanup pass can move historical plans/specs into `docs/superpowers/archive/`
after this status document is accepted as the source of truth.
