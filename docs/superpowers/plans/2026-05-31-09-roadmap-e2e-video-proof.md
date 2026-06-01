# Roadmap E2E Video Proof Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Verify the repaired Harmony roadmap with deterministic local runtime flows, browser/API proof, and recorded Playwright/Chrome DevTools evidence for every release-blocking milestone.

**Architecture:** Keep unit and DB tests as the first gate, then run a local Postgres-backed Harmony runtime with fake Linear/GitHub sources. Each milestone gets a deterministic scenario that drives one poll cycle, exposes the resulting state through `/projects`, `/`, and `/api/v1/state`, and records video plus API evidence. Only after a manual proof is repeatable should it become an automated browser smoke test.

**Tech Stack:** Elixir/OTP, Ecto/Postgres, Podman or Docker Compose, Phoenix LiveView dashboard, JSON observability API, Playwright MCP, Chrome DevTools MCP.

---

## Current Baseline

- The roadmap repair code is already implemented on the current branch: durable work runs, PR observation, restart-safe dedupe/blockers/events, runtime handoff to Human Review, browser evidence persistence/gating, and failed CI log context.
- Local Postgres now runs with Podman using `docker.io/library/postgres:16-alpine`; `podman compose` resolves through the installed `podman-compose` provider.
- The local Postgres container creates both `harmony_dev` and `harmony_test`.
- `mix test --seed 0` passes against the Podman Postgres instance.
- The remaining work in this plan is E2E proof, video artifacts, and any small harness code required to make the proof repeatable without live Linear/GitHub writes.

## Evidence Output

Use this artifact layout:

```text
docs/evidence/roadmap-e2e/
  milestone-01-workrun-pr-observation.webm
  milestone-01-workrun-pr-observation.json
  milestone-02-dedupe-blockers-events.webm
  milestone-02-dedupe-blockers-events.json
  milestone-03-implementation-handoff.webm
  milestone-03-implementation-handoff.json
  milestone-04-browser-evidence-gate.webm
  milestone-04-browser-evidence-gate.json
  milestone-05-failed-ci-context.webm
  milestone-05-failed-ci-context.json
  final-review-checks.md
```

Each JSON sidecar should include:

- command log summary,
- runtime URL,
- project id and slug,
- work run id,
- dedupe key,
- blocker id when present,
- API payload excerpt,
- browser tool used,
- video path,
- screenshots or traces when collected.

## Task 0: Local Runtime Gate

**Files:**
- Modify: `elixir/docker-compose.yml` only if the local container contract changes.
- Modify: `elixir/README.md` only if local Postgres instructions change.

- [ ] Start local Postgres from `elixir/`.

```bash
podman compose up -d postgres
```

If Compose is unavailable, use the direct Podman fallback:

```bash
podman run -d --name harmony-postgres \
  -e POSTGRES_USER=postgres \
  -e POSTGRES_PASSWORD=postgres \
  -e POSTGRES_DB=harmony_dev \
  -p "${HARMONY_DATABASE_PORT:-5432}:5432" \
  -v harmony_postgres_data:/var/lib/postgresql/data \
  -v "$PWD/priv/docker/postgres/init:/docker-entrypoint-initdb.d:ro" \
  docker.io/library/postgres:16-alpine
```

- [ ] Verify both databases exist.

```bash
podman exec harmony-postgres psql -U postgres -d harmony_dev \
  -tAc "SELECT datname FROM pg_database WHERE datname IN ('harmony_dev', 'harmony_test') ORDER BY datname;"
```

- [ ] Run migrations.

```bash
cd elixir
mix ecto.migrate
MIX_ENV=test mix ecto.migrate
```

- [ ] Run the local automated gate.

```bash
cd elixir
mix format --check-formatted
mix specs.check
mix test --seed 0
```

Expected: all commands exit 0 before recording browser proof.

## Task 1: Deterministic Roadmap Scenario Harness

**Files:**
- Create: `elixir/lib/mix/tasks/harmony.roadmap_e2e.ex`
- Create: `elixir/test/symphony_elixir/roadmap_e2e_harness_test.exs`
- Modify: `elixir/test/support/test_support.exs` only if shared fake source helpers are useful.

- [ ] Add a dev/test-only Mix task that can seed and drive fake roadmap scenarios without real GitHub or Linear writes.
- [ ] The task must accept a scenario name: `milestone1`, `milestone2`, `milestone3_success`, `milestone3_blocker`, `milestone4`, `milestone5`.
- [ ] Each scenario must:
  - upsert a deterministic project,
  - install fake Linear/GitHub work source fetchers,
  - trigger exactly one poll cycle or a documented sequence of poll cycles,
  - print the runtime URL, project slug, work run ids, dedupe keys, and expected UI/API assertions.
- [ ] The task must never call live GitHub or Linear clients.
- [ ] Add unit tests that verify each scenario seeds the expected durable rows and does not depend on external network access.

Validation:

```bash
cd elixir
mix test test/symphony_elixir/roadmap_e2e_harness_test.exs --seed 0
```

## Task 2: Milestone 1 Proof - Durable WorkRun And PR Observation

**Scenario:** `mix harmony.roadmap_e2e milestone1 --port 4000`

- [ ] Start the runtime with local Postgres and fake sources.
- [ ] Trigger one controlled poll that emits:
  - a Linear implementation `WorkRun` with `payload.project_id`,
  - a GitHub PR observation that persists or updates `pull_request_links`.
- [ ] Use Playwright MCP video recording:
  - open `/projects`,
  - open `/`,
  - open `/api/v1/state`,
  - show the project, queued/running work, and PR linkage evidence.
- [ ] Use Chrome DevTools MCP:
  - collect console messages,
  - inspect the `/api/v1/state` network response,
  - capture a desktop screenshot and a mobile viewport screenshot.
- [ ] Save `milestone-01-workrun-pr-observation.webm` and JSON sidecar.
- [ ] If repeatable, add an automated browser smoke that checks `/projects`, `/`, and `/api/v1/state` for the seeded project and no dashboard regression.

Expected proof: the runtime state shows the project-backed implementation work run and a PR link derived from fake GitHub PR observation.

## Task 3: Milestone 2 Proof - Restart-Safe Dedupe, Blockers, Events

**Scenario:** `mix harmony.roadmap_e2e milestone2 --port 4000`

- [ ] Seed an unsafe failed-CI PR work run with a deterministic dedupe key.
- [ ] Trigger the first poll and verify:
  - a durable blocker exists,
  - the dedupe key status is `blocked`,
  - no agent dispatch occurs,
  - external handoff writes emit `work_events`.
- [ ] Simulate restart by stopping and starting a fresh runtime process, or by running the scenario in restart mode against the same database.
- [ ] Trigger the second poll and verify it does not create a duplicate comment, blocker, dedupe row, or dispatch.
- [ ] Record Playwright video over `/`, `/projects`, and `/api/v1/state`.
- [ ] Use Chrome DevTools MCP to capture network response and console health.
- [ ] Save `milestone-02-dedupe-blockers-events.webm` and JSON sidecar.
- [ ] If repeatable, add an automated browser/API smoke for blocked count and stable API payload after refresh.

Expected proof: the second poll is suppressed by durable blocker/dedupe state, while the dashboard/API still make the blocked state understandable.

## Task 4: Milestone 3 Proof - Runtime Handoff For Linear Issue Workflow

**Scenarios:**
- `mix harmony.roadmap_e2e milestone3_success --port 4000`
- `mix harmony.roadmap_e2e milestone3_blocker --port 4000`

- [ ] Success path: seed implementation completion with a valid PR link and verify Linear state update target is `Human Review`.
- [ ] Blocker path: seed completion without a PR link and verify a blocker plus Linear comment are recorded.
- [ ] Verify bad base/head branch policy creates a blocker.
- [ ] Verify no scenario sets Linear `Done`.
- [ ] Verify no scenario merges a PR.
- [ ] Record dashboard/API video for success and blocker states.
- [ ] Save `milestone-03-implementation-handoff.webm` and JSON sidecar.

Expected proof: implementation completion is a runtime handoff to Human Review, not a prompt-only convention and not a final Done/merge action.

## Task 5: Milestone 4 Proof - Browser Evidence Runtime Gate

**Scenario:** `mix harmony.roadmap_e2e milestone4 --port 4000`

- [ ] Seed a frontend-changing implementation work run that requires browser evidence.
- [ ] Verify handoff without artifacts records a blocker.
- [ ] Add a valid evidence manifest with screenshot/report/trace artifact metadata under the workspace.
- [ ] Verify artifact metadata persists with `work_run_id`.
- [ ] Verify path traversal artifacts are rejected by automated tests before manual proof.
- [ ] Record Playwright video showing the dashboard Evidence section on desktop and mobile.
- [ ] Use Chrome DevTools MCP to inspect layout, console errors, and `/api/v1/state` artifact payload.
- [ ] Save `milestone-04-browser-evidence-gate.webm` and JSON sidecar.

Expected proof: frontend changes cannot hand off without evidence, and valid evidence appears in dashboard/API with stable artifact metadata.

## Task 6: Milestone 5 Proof - Failed CI Logs And Repair Context

**Scenario:** `mix harmony.roadmap_e2e milestone5 --port 4000`

- [ ] Seed an open PR with a failed GitHub Actions workflow run and deterministic log excerpt.
- [ ] Trigger one poll and verify a `ci_fix` work run is created.
- [ ] Verify payload includes `workflow_run`, `log_excerpt`, run id, workflow name, and URL.
- [ ] Seed a log fetch error variant and verify polling does not crash and records `log_fetch_error`.
- [ ] Verify unknown or non-GitHub-Actions checks do not trigger repair.
- [ ] Record dashboard/API video showing queued or running CI-fix context.
- [ ] Save `milestone-05-failed-ci-context.webm` and JSON sidecar.

Expected proof: CI-fix agents receive enough workflow/log context to repair, and unsupported checks do not create unsafe repair work.

## Task 7: Final Browser Review Pass

**Files:**
- Create: `docs/evidence/roadmap-e2e/final-review-checks.md`

- [ ] Use Playwright MCP desktop viewport on `/`, `/projects`, `/projects/new`, and `/api/v1/state`.
- [ ] Use Playwright MCP mobile viewport on `/`, `/projects`, and `/projects/new`.
- [ ] Use Chrome DevTools MCP to check console errors and network failures.
- [ ] Verify dashboard text does not overlap or truncate in running, retrying, blocked, and evidence sections.
- [ ] Verify raw project config JSON validation errors are readable.
- [ ] Verify dashboard diagnostics expose sandbox posture and warnings.
- [ ] Verify UI never suggests automerge, Linear `Done`, or automatic production rollout.
- [ ] Record any residual UI issues in `final-review-checks.md` with screenshot paths.

## Task 8: Final Quality Gate And Review

- [ ] Run whitespace and format checks.

```bash
git diff --check
cd elixir
mix format --check-formatted
mix specs.check
```

- [ ] Run full tests.

```bash
cd elixir
mix test --seed 0
```

- [ ] Run the project-level gate when local dependencies are ready.

```bash
cd elixir
make all
```

- [ ] Request independent code review over:
  - roadmap repair implementation,
  - Postgres local setup,
  - E2E harness,
  - dashboard/API proof artifacts,
  - browser evidence artifacts.

Expected: PASS or PASS WITH NO RELEASE-BLOCKING FINDINGS before any manual production runtime run.
