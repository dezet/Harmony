# Harmony Roadmap Plan Set Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Execute the Harmony production roadmap through ordered, independently reviewable implementation plans.

**Architecture:** The roadmap is split into eight milestone plans. Each plan produces a working increment with its own tests and commits; later plans depend on the durable storage, project config, and runtime policy foundations introduced first.

**Tech Stack:** Elixir/OTP, Ecto/Postgres, Phoenix dashboard, GitHub REST API, Linear GraphQL, Codex app-server, Playwright/Chrome MCP tooling.

---

## Execution Order

1. `docs/superpowers/plans/2026-05-31-01-postgres-project-config.md`
2. `docs/superpowers/plans/2026-05-31-02-runtime-policy-workrun.md`
3. `docs/superpowers/plans/2026-05-31-03-github-integration-foundation.md`
4. `docs/superpowers/plans/2026-05-31-04-failed-ci-fix-workflow.md`
5. `docs/superpowers/plans/2026-05-31-05-hreview-workflow.md`
6. `docs/superpowers/plans/2026-05-31-06-browser-evidence.md`
7. `docs/superpowers/plans/2026-05-31-07-operations-hardening.md`
8. `docs/superpowers/plans/2026-05-31-08-platform-expansion.md`

Post-repair E2E proof plan:

- `docs/superpowers/plans/2026-05-31-09-roadmap-e2e-video-proof.md`

## Current Implementation Status

Status as of 2026-06-01 on branch `harmony-roadmap-mvp` / PR #3:
`https://github.com/dezet/Harmony/pull/3`.

The plan files below are historical implementation plans. Their unchecked
checkboxes are not the source of truth for current status until each plan is
converted into an archive/status format.

| Milestone | Status | Concrete findings |
| --- | --- | --- |
| 1. Postgres and project config | Implemented | Storage tables are in `elixir/priv/repo/migrations/20260531010000_create_harmony_storage.exs:7`; storage APIs start at `elixir/lib/symphony_elixir/storage.ex:11`; project YAML sync is in `elixir/lib/symphony_elixir/project_config/sync.ex:25`. |
| 2. Runtime policy and WorkRun | Implemented | WorkRun persistence is in `elixir/lib/symphony_elixir/storage.ex:91`; durable blockers are in `elixir/lib/symphony_elixir/storage.ex:152`; handoff policy is in `elixir/lib/symphony_elixir/runtime_policy/implementation_handoff.ex:10`. |
| 3. GitHub integration foundation | Implemented | GitHub PR observation/persistence flows through `elixir/lib/symphony_elixir/work_sources/github_pr_source.ex:1` and `elixir/lib/symphony_elixir/storage.ex:244`. |
| 4. Failed CI fix workflow | Implemented | Failed GitHub Actions polling is in `elixir/lib/symphony_elixir/work_sources/github_failed_ci_source.ex:10`; log/error payload handling is in `elixir/lib/symphony_elixir/work_sources/github_failed_ci_source.ex:87`. |
| 5. `@hreview` workflow | Implemented | Review trigger/dedupe source is in `elixir/lib/symphony_elixir/work_sources/github_review_request_source.ex:15`; inline diff comment mapping is in `elixir/lib/symphony_elixir/workflows/inline_review_comments.ex:21`. |
| 6. Browser evidence MVP | Implemented and covered by v2 proof | Evidence manifest parsing is in `elixir/lib/symphony_elixir/evidence/manifest.ex:22`; handoff evidence gate is in `elixir/lib/symphony_elixir/runtime_policy/handoff.ex:28`; e2e proof is `docs/evidence/roadmap-e2e/milestone-04-browser-evidence-gate-v2.webm`. |
| 7. Operations hardening | Implemented as tooling/runbook; rollout proof missing | Sandbox diagnostics are in `elixir/lib/symphony_elixir/diagnostics/sandbox.ex:26`; operations runbook starts at `docs/harmony-operations.md:55`. No repo-recorded post-v2 host/systemd proof was found. |
| 8. Platform expansion | Partially implemented | Project UI, webhooks, multi-project scheduling, inline comments, and video evidence exist. Claude Code and Pi are capability spikes only: `elixir/lib/symphony_elixir/agent_backends/claude_code.ex:11` and `elixir/lib/symphony_elixir/agent_backends/pi.ex:11` return execution-not-implemented errors. |
| 9. Roadmap E2E video proof | Mostly complete; independent review open | V2 videos and sidecars are present under `docs/evidence/roadmap-e2e/`. `docs/superpowers/plans/2026-05-31-09-roadmap-e2e-video-proof.tasks.md:101` still tracks independent review and release-blocking findings. |

## Cross-Plan Rules

- Keep `WORKFLOW.md` as global runtime policy and prompt contract.
- Keep per-project runtime settings in `projects/<slug>.yaml`, synced into Postgres.
- Do not enable automatic merging or automatic Linear `Done`.
- Preserve current Linear polling behavior while adding GitHub work sources.
- Every external write must produce a `work_event`.
- Every trigger that could repeat after restart must use a persisted `dedupe_key`.
- Every blocker must be persisted and must suppress retry loops for the same target/reason.

## Global Validation

Run after each milestone when local dependencies are available:

```bash
cd elixir
mix format --check-formatted
mix specs.check
mix test
```

Run before calling the full MVP production-ready:

```bash
cd elixir
make all
```

Expected: the commands exit 0. If local Postgres is unavailable, record the exact failure and run all non-DB targeted tests for the milestone.

## Manual Integration Gates

Use controlled manual runs after the following milestones:

- Milestone 2: existing Linear issue -> PR -> Human Review proof-of-life.
- Milestone 4: disposable failed GitHub Actions PR.
- Milestone 5: disposable PR comment with `@hreview`.
- Milestone 6: frontend test PR requiring browser evidence.
- Milestone 7: dedicated `harmony` user setup and manual systemd start.

Each manual run must record:

- project slug,
- repo and PR,
- Linear issue when linked,
- work run id,
- dedupe key,
- validation commands,
- blocker or handoff result,
- artifact paths when browser evidence is required.
