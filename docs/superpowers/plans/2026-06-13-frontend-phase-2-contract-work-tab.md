# Frontend Phase 2: Contract + Work Tab Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Per-project REST contract (`projects/:ref/summary`, paginated `work_runs`) and the `/projects/:slug` workspace with the Work tab, per Phase 2 of `docs/superpowers/specs/2026-06-12-frontend-uiux-design.md`.

**Architecture:** Backend adds two read-only endpoints built from existing Storage/Presenter/Orchestrator patterns; frontend adds the project workspace route with a three-column Work tab (live data from the summary endpoint) and a cursor-paginated history table on a new shared `DataTable` (TanStack Table). Contract fixtures are shared backend↔frontend like `state_payload.fixture.json`.

**Tech Stack:** Elixir/Phoenix + Ecto, React 19, TanStack Query (`useInfiniteQuery`) + new dep `@tanstack/react-table` (^8.21).

**Working directories:** Elixir from `elixir/` (`mix test`), frontend from `elixir/assets/`.

## Locked decisions (from the architecture pass — do not relitigate)

1. **Project resolution:** `GET /api/v1/projects/:project_ref/summary` accepts UUID **or** slug (try UUID cast first, fall back to `Storage.get_project_by_slug/1`, which exists). `work_runs` takes `?project=<slug>`.
2. **Summary includes live lists:** the endpoint returns `running`/`retrying`/`blocked` filtered from the orchestrator snapshot (entries already carry `project` refs via `Presenter` entry payloads) plus `human_review_prs` from durable `PullRequestLink` rows (ordered `updated_at DESC`). The Work tab does NOT client-side-filter the dashboard payload.
3. **No CI status invention:** `PullRequestLink` has no CI field; expose `metadata` verbatim. Frontend shows a CI badge only if `metadata?.ci_status` is present (it won't be yet).
4. **Pagination:** order `inserted_at DESC, id DESC`; opaque cursor = base64url JSON `{"inserted_at","id"}`; `WHERE (inserted_at, id) < cursor` composite; fetch `page_size + 1` to compute `meta.next_cursor` (null on last page). `page_size` default 25, cap 100. `updated_at` is NOT a valid cursor (mutates on upsert). `payload` column omitted from list responses.
5. **Routes:** new API routes go BEFORE the `get("/api/v1/:issue_identifier", ...)` catch-all in `router.ex`. Frontend `projects/:slug` route coexists with `projects/new` (static wins) and `projects/:id/edit` (distinct second segment).
6. **Tabs:** workspace renders tab bar Work | Evidence | Activity | Configuration; only Work is functional; the other three are disabled buttons (local `useState`, no per-tab routes in Phase 2).
7. **Navigation:** sidebar project rows repoint to `/projects/:slug` (null-guard on slug → `/projects`); Sidebar.test href assertion updated. `ProjectsPage` keeps its Edit→`/projects/:id/edit` link (different surface). `crumbsFor` gains the `/projects/:slug` branch (label = slug from URL, no async lookup).
8. **Per-section errors:** each Work-tab section and the history table renders its own destructive Alert + retry on query error; the page shows a 404 state for unknown slugs. Elapsed times only via `<ElapsedTime>`.

## Response shapes (the contract — fixtures must match)

`GET /api/v1/projects/:project_ref/summary` → 200:

```json
{
  "project": { "id", "slug", "github_owner", "github_repo", "github_base_branch",
               "linear_project_slug", "linear_team_key", "linear_human_review_state",
               "config_version" },
  "counts": { "running": 0, "retrying": 0, "blocked": 0 },
  "running":  [ { ...running_entry_payload fields, no "project" key... } ],
  "retrying": [ { ...retry_entry_payload fields, no "project" key... } ],
  "blocked":  [ { ...blocked_entry_payload fields, no "project" key... } ],
  "human_review_prs": [ { "id", "github_owner", "github_repo", "github_pr_number",
                          "github_head_sha", "github_head_ref", "github_base_ref",
                          "linear_identifier", "linear_url", "metadata" } ]
}
```

404 → `{"error":{"code":"not_found","message":"Project not found"}}` (existing FallbackController envelope).

`GET /api/v1/work_runs?project=&status=&cursor=&page_size=` → 200:

```json
{
  "work_runs": [ { "id", "project_id", "type", "status", "dedupe_key",
                   "github_owner", "github_repo", "github_pr_number", "github_head_sha",
                   "github_head_ref", "github_base_ref", "linear_issue_id",
                   "linear_identifier", "linear_url", "agent_backend",
                   "inserted_at", "updated_at" } ],
  "meta": { "next_cursor": "base64url-or-null", "page_size": 25 }
}
```

Missing/unknown `project` slug → 404 envelope as above.

## Tasks

Verification gates for every task: backend tasks `mix test` from `elixir/`; frontend tasks `npm run test -- --run && npm run typecheck && npm run lint` from `elixir/assets/`. TDD: failing test first. Conventional commits ending with the AI footer.

### Task A: Storage queries

**Files:** modify `elixir/lib/symphony_elixir/storage.ex`; tests in the existing storage test file (follow its setup/`@tag` patterns).

- [ ] `list_work_runs_for_project(project_id, opts)` — filters by project_id, optional `status`, optional decoded cursor (composite `inserted_at`/`id` condition), `order_by [desc: :inserted_at, desc: :id]`, `limit page_size + 1`.
- [ ] Cursor helpers: `encode_work_run_cursor(run)` / `decode_work_run_cursor(binary)` (base64url JSON, tolerant decode → `:error` ignored = unfiltered first page). Put them in Storage so the controller and Presenter share them.
- [ ] `list_pull_request_links_for_project(project_id)` — `order_by desc: :updated_at`.
- [ ] Tests: insert 3+ work runs with distinct `inserted_at`, assert ordering, status filter, cursor page 2, `+1` overfetch behavior; PR links ordering. Commit.

### Task B: Presenter projections

**Files:** modify `elixir/lib/symphony_elixir_web/presenter.ex`; pure-function tests.

- [ ] `project_summary_payload(project, snapshot)` — project block (fields listed above), live entries filtered by project id/slug match on the entry's project payload, with the `project` key stripped from each entry; counts derived from the filtered lists; `human_review_prs` from Task A query. Reuse the existing `running_entry_payload`/`retry_entry_payload`/`blocked_entry_payload` functions — do not duplicate their field logic.
- [ ] `work_run_list_payload(runs, page_size)` — slice overfetched list, build `meta.next_cursor` from the last visible row via Task A's encoder, omit `payload` column. Timestamps ISO 8601 UTC.
- [ ] Tests for both (snapshot fixture in-test; no HTTP). Commit.

### Task C: Summary endpoint

**Files:** create `elixir/lib/symphony_elixir_web/controllers/project_summary_controller.ex`; modify `router.ex`; create `elixir/test/symphony_elixir/project_summary_api_test.exs`; create fixture `elixir/assets/src/test/fixtures/project_summary.fixture.json`.

- [ ] Controller mirrors `ObservabilityApiController`'s orchestrator-snapshot access pattern and `ProjectController`'s fallback usage; `fetch_project/1` tries `Ecto.UUID.cast` → `get_project!` (rescue NoResultsError) else `get_project_by_slug` → `{:error, :not_found}`.
- [ ] Route `get("/api/v1/projects/:project_ref/summary", ...)` before the `:issue_identifier` catch-all; `match(:*, ...)` method-not-allowed guard consistent with siblings.
- [ ] Tests: 404 unknown ref; resolves by slug AND by UUID; live entries filtered to the project; PR links present; response shape matches the fixture file (follow the exact pattern of the existing test that asserts `state_payload.fixture.json` — find it first and mirror it).
- [ ] Write the fixture with realistic data (one running, one retrying, one blocked, one PR). Commit.

### Task D: Work-runs endpoint

**Files:** create `elixir/lib/symphony_elixir_web/controllers/work_run_controller.ex`; modify `router.ex`; create `elixir/test/symphony_elixir/work_run_api_test.exs`; fixture `elixir/assets/src/test/fixtures/work_runs_page.fixture.json`.

- [ ] Controller: missing/unknown `project` param → 404; `status`/`cursor`/`page_size` (default 25, cap 100, tolerant int parse) → Storage → Presenter.
- [ ] Tests: pagination across 2 pages with stable cursor; status filter; cap on page_size; 404; fixture shape assertion. Commit.

### Task E: Frontend contract + data layer

**Files:** modify `src/types/contract.ts`, `src/lib/api.ts`, `src/lib/queryClient.ts`; extend `src/types/contract.test.ts`; create `src/features/project/useProjectSummary.ts`, `src/features/project/useWorkRuns.ts`.

- [ ] Types: `ProjectSummary`, `SummaryRunningEntry`/reuse (running/retrying/blocked entries are the existing types minus `project` — model as `Omit<RunningEntry, "project">` etc.), `HumanReviewPR`, `WorkRunListItem`, `WorkRunsPage`, `WorkRunFilters`.
- [ ] `api.ts`: `getProjectSummary(ref)`, `getWorkRuns(slug, filters, cursor?)` (URLSearchParams; reuse `ApiError`).
- [ ] `queryClient.ts`: `PROJECT_SUMMARY_KEY(slug)`, `WORK_RUNS_KEY(slug, filters)` factories.
- [ ] Hooks: `useProjectSummary(slug)` (`staleTime: 30_000`); `useWorkRuns(slug, filters)` via `useInfiniteQuery` + `getNextPageParam: (last) => last.meta.next_cursor ?? undefined`.
- [ ] Contract tests: import both fixture JSONs, assert they satisfy the TS types (mirror existing `contract.test.ts` style). Commit.

### Task F: DataTable + StatusBadge

**Files:** `npm install @tanstack/react-table`; create `src/components/DataTable.tsx`, `src/components/StatusBadge.tsx`, tests for both.

- [ ] `DataTable<TData>`: props `columns: ColumnDef<TData>[]`, `data`, `hasNextPage?`, `onLoadMore?`, `isLoading?`; renders shadcn Table, client-side sorting via TanStack `getSortedRowModel` (clickable headers), "Load more" button when `hasNextPage`. Keep it lean — no column filters UI in Phase 2.
- [ ] `StatusBadge`: status string → Badge variant map (`completed`→secondary, `failed`/`blocked`→destructive, `running`/`queued`→outline, default outline); renders the raw status text.
- [ ] Tests: rows render; header click toggles sort order; Load more fires callback; StatusBadge variants. Commit.

### Task G: Workspace page + Work tab

**Files:** create `src/features/project/ProjectWorkspacePage.tsx`, `src/features/project/WorkTab.tsx`, `src/features/project/components/{RunningColumn,RetryBlockedColumn,HumanReviewColumn,WorkRunHistoryTable}.tsx` + tests for page and tab; modify `src/App.tsx` (route `projects/:slug` between `projects/new` and `projects/:id/edit`).

- [ ] Page: `useParams` slug → `useProjectSummary`; skeleton; 404 ApiError → not-found state with link back to `/projects`; header (slug + health dot via `projectHealth(counts)` + counts); tab bar (Work active, other three disabled with "coming soon" empty state); renders `<WorkTab summary>`.
- [ ] WorkTab: responsive 3-column grid (Running / Retry + Blocked / → Human Review) of Cards reusing `<ElapsedTime>`, `StatusBadge`, mono identifiers; each column has its own empty state; below, `WorkRunHistoryTable` (own `useWorkRuns`, flattened pages → `DataTable`, columns: identifier (linear_identifier, mono), type, status (StatusBadge), PR (#number linked to GitHub when owner/repo/number present), updated). Section-level error Alerts with retry buttons (use `refetch`).
- [ ] Tests: page renders header+tabs from stubbed fetch of the summary fixture; 404 path; WorkTab renders the three columns + PR link from fixture data. Commit.

### Task H: Navigation repoint + e2e + docs

**Files:** modify `src/components/layout/Sidebar.tsx`, `Sidebar.test.tsx`, `src/components/layout/Breadcrumbs.tsx`, `Breadcrumbs.test.tsx`, `e2e/react-spa.spec.ts`, `elixir/assets/CLAUDE.md`; check the e2e fixture server (`elixir/lib/mix/tasks/harmony.react_spa_e2e_server.ex`) serves the new endpoints (extend it if the workspace e2e needs them).

- [ ] Sidebar row link → `` p.slug ? `/projects/${p.slug}` : "/projects" ``; update test assertion (`href="/projects/alpha"`).
- [ ] `crumbsFor`: in the projects branch add `else if (second && !third) crumbs.push({ label: second, to: \`/projects/${second}\` })`; test for `/projects/alpha` → Overview/Projects/alpha.
- [ ] e2e: sidebar project click → workspace heading with slug visible, Work tab default, at least one column heading visible. Extend the e2e fixture server with deterministic summary/work_runs responses if needed.
- [ ] CLAUDE.md routing note: add `/projects/:slug`. Full gates: unit+typecheck+lint+build, `make e2e`. Commit.

## Out of scope (later phases)

Run detail + per-run channel (Phase 3); Evidence/Activity/Configuration tabs (Phase 4); stop/retry actions, rate-limit rendering (Phase 5).
