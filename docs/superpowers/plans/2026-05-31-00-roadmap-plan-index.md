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

