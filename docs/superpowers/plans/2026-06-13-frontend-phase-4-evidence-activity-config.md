# Frontend Phase 4: Evidence, Activity & Configuration Tabs Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the three remaining project-workspace tabs real — Evidence (artifacts grouped by run, content served via `GET /api/v1/artifacts/:id`), Activity (cursored project-wide work-events feed), Configuration (the project form with a CodeMirror JSON editor) — per Phase 4 of `docs/superpowers/specs/2026-06-12-frontend-uiux-design.md`.

**Architecture:** Three new read endpoints built on the established Storage/Presenter/controller patterns; one file-serving endpoint with a strict security posture; URL-driven tab state (`?tab=`); the existing project form extracted into a shared component reused by both the standalone routes and the Configuration tab.

**Locked decisions (from the architecture pass):**
1. **Tab state via `?tab=` search param** (default/invalid → "work") — keeps the single `useProjectSummary` fetch and satisfies deep-linking without router restructuring.
2. **Artifact endpoint security:** artifact UUID is the ONLY untrusted input; the DB row is the allowlist. At serve time: re-`Path.expand` the stored path and require the `workspace.root` prefix (404 on miss, 403 on escape), `File.stat` size cap 100 MB (413), static kind→content-type map (screenshot→image inline by extension png/jpg/gif; report/video/trace→`attachment` download; no MIME sniffing), `send_file`. `path` is NEVER exposed in list responses.
3. **Evidence data:** new `GET /api/v1/projects/:project_ref/artifacts` (separate `ProjectArtifactsController`) on `Storage.list_artifacts_for_project/1` (preload `:work_run`, asc inserted_at; no pagination — artifacts are sparse). Frontend groups by `work_run_id`; screenshots as `<img src={getArtifactUrl(id)}>` thumbnails, the rest as download links.
4. **Activity data:** new `GET /api/v1/projects/:project_ref/activity?cursor=&page_size=` on `Storage.list_work_events_for_project/2` (same ascending cursor pattern as run stream; reuse `stream_event_payload`; meta has `next_cursor` only — no `has_live`). Do NOT extend the run-stream endpoint.
5. **Configuration:** extract `ProjectConfigForm` from `ProjectFormPage` (same fields, same Yup schema, `config_json` stays a string field); CodeMirror (`@uiw/react-codemirror` ^4.23 + `@codemirror/lang-json` ^6) replaces the Textarea via react-hook-form `Controller`. `/projects/new` and `/projects/:id/edit` STAY (shared component); ConfigurationTab lazy-fetches the full project (`useProject(id, enabled: tab active)`) because the summary payload deliberately omits `config`. On save: toast + invalidate `PROJECT_SUMMARY_KEY(slug)`.
6. **Per-tab isolation:** each tab owns its loading skeleton + destructive Alert/Retry; a tab failure never breaks the workspace header.
7. Fixtures live in `elixir/assets/src/test/fixtures/` (established shared-contract location): `project_artifacts_page.fixture.json`, `project_activity_page.fixture.json`.
8. New routes go before the `:issue_identifier` catch-all with `match(:*)` 405 guards; FallbackController gains `{:error, :artifact_not_found}` (404) and `{:error, :artifact_path_unsafe}` (403).

**Response shapes:**
- Artifacts page: `{"artifacts": [{id, kind, metadata, work_run_id, work_run: {linear_identifier, status, inserted_at} | null}]}` (no `path`).
- Activity page: `{"items": [RunStreamItem...], "meta": {"next_cursor": string|null}}`.
- `GET /api/v1/artifacts/:id`: binary body.

## Tasks

Gates per task: backend `mise exec -- mix test`; frontend `npm run test -- --run && npm run typecheck && npm run lint`. TDD. Conventional commits + AI footer.

### Task A: Storage queries
`get_artifact/1` (Repo.get), `list_artifacts_for_project/1` (where project_id, preload :work_run, asc inserted_at), `list_work_events_for_project/2` (project_id-scoped clone of the run-events cursor query — share private helpers where clean). Tests incl. preload presence, cursor page-2, scoping.

### Task B: Artifact content endpoint (security-critical)
`ArtifactController.show/2` per Locked decision 2 + `method_not_allowed`; FallbackController clauses; route + guard. Tests MUST include: unknown UUID → 404; artifact row whose path is OUTSIDE workspace root (insert directly, bypassing the manifest validator) → 403; valid temp file under a test workspace root → 200 with expected bytes + content-type + disposition per kind (screenshot inline, video attachment); non-GET → 405. Read how `Config.settings!()`/workspace root is accessed elsewhere and use the same mechanism; in tests, point the workspace root at a tmp dir the same way existing workspace tests do (find one first).

### Task C: Listing endpoints + Presenter + fixtures
`ProjectArtifactsController` + `ProjectActivityController` (project_ref resolution copied from ProjectSummaryController), `Presenter.project_artifacts_payload/1` (+ per-item payload omitting `path`) and `project_activity_payload/2` (reuse `stream_event_payload`), routes + guards, both fixtures + key-set contract tests, API tests (404s, shapes, activity pagination 2 pages, artifacts grouped data with and without work_run).

### Task D: Frontend deps + JsonEditor + URL tabs
`npm install @uiw/react-codemirror @codemirror/lang-json` (only these). `src/components/JsonEditor.tsx` ({value, onChange, readOnly?, "aria-label"?}; json() extension; test: renders value, onChange fires). `ProjectWorkspacePage`: `useSearchParams`-driven `activeTab` (invalid → work), enable all four tab buttons (work button clears the param), conditional tab panels (stubs "Coming soon" for the three until Tasks E-F land — keep disabled=false), tests: clicking Evidence sets `?tab=evidence`; rendering at `?tab=activity` shows that panel; invalid tab → work.

### Task E: Configuration tab
Extract `ProjectConfigForm` (props: `project?: Project`, `onSuccess`) from ProjectFormPage; swap Textarea → JsonEditor via `Controller`; refactor ProjectFormPage to use it (routes unchanged, its tests must keep passing — update render expectations if the editor changes textbox semantics: CodeMirror is NOT a textarea; adjust form tests to interact via the Controller value or test the form logic with JsonEditor mocked — report approach). `ConfigurationTab.tsx`: lazy `useProject` (enabled on tab), loading/error states, renders the form, on success toast + invalidate summary. Tests: form prefill, submit calls update API, tab lazy-fetch gating.

### Task F: Evidence + Activity tabs
Data layer: `getProjectArtifacts`, `getProjectActivity`, `getArtifactUrl(id)` (pure URL builder), `ARTIFACTS_KEY`/`ACTIVITY_KEY`, `ProjectArtifact`/`ProjectArtifactsPage`/`ProjectActivityPage` types + fixture contract tests, `useProjectArtifacts` (useQuery), `useProjectActivity` (useInfiniteQuery, inference-typed). Components: `EvidenceTab` (group by work_run_id; group card header = mono identifier + StatusBadge + ElapsedTime of run inserted_at; screenshot `<img>` linking to the artifact URL, others `<a href download>` rows; empty → "No evidence yet."), `ActivityTab` (flattened pages → reuse `StreamItemRow`; Load more; empty → "No activity yet."). Tests fixture-driven incl. grouping and img-vs-link logic.

### Task G: Integration + e2e + docs
Wire real tabs into ProjectWorkspacePage (replace stubs), update its tests. e2e: seed one screenshot artifact (write a small PNG into the e2e workspace tmp dir + artifact row) and one extra work_event in the fixture server; test: `?tab=evidence` shows the artifact group with the run identifier and an img; `?tab=activity` shows an event row; `?tab=configuration` shows the form with the project slug prefilled; direct-load deep link works. CLAUDE.md notes (tabs + JsonEditor + new endpoints). Full gates incl. `npm run build` and `mise exec -- make e2e`.

## Out of scope
Stop/Retry actions, rate-limit rendering, channel auth (Phase 5); artifact pagination; inline video playback.
