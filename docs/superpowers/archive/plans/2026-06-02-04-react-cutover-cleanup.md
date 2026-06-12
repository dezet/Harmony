# Phase 3 — Cutover + Cleanup Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the React SPA the default UI at `/`, remove the Phoenix LiveView UI and the legacy asset pipeline, drop the `phoenix_live_view` dependency, and repoint the e2e harness at the React app.

**Architecture:** Flip Vite's `base` to `/`, serve the build at the root via `Plug.Static` + a root SPA fallback (defined AFTER the API/webhook routes and the new socket so it cannot shadow them). Delete the LiveViews, the root layout, the static-asset controller/module, and `dashboard.css`. Remove the `:phoenix_live_view` compiler/dep and the `/live` socket. Update tests and the Playwright harness.

**Tech Stack:** Phoenix endpoint/router, Mix config, ExUnit, Playwright e2e.

**Prereq:** Phases 0–2 complete and validated. This phase changes behavior at `/` — do it last.

---

## File Structure

- Modify: `elixir/assets/vite.config.ts` (`base: "/"`)
- Modify: `elixir/lib/symphony_elixir_web/endpoint.ex` (Static at `/`, remove `/live` socket)
- Modify: `elixir/lib/symphony_elixir_web/router.ex` (remove LiveView + legacy asset routes; root SPA fallback)
- Modify: `elixir/lib/symphony_elixir_web/controllers/spa_controller.ex` (serve at `/`)
- Modify: `elixir/mix.exs` (remove `:phoenix_live_view` dep + compiler; clean `ignore_modules`)
- Delete: `live/dashboard_live.ex`, `live/projects_live.ex`, `live/project_form_live.ex`, `components/layouts.ex`, `controllers/static_asset_controller.ex`, `static_assets.ex`, `priv/static/dashboard.css`
- Delete/replace: `test/symphony_elixir/project_ui_test.exs` and any LiveView-only assertions; update the Playwright harness.

---

### Task 1: Discover every LiveView / legacy-asset reference

**Files:** none changed (discovery only)

- [ ] **Step 1: Enumerate references to remove or update**

```bash
cd /work/Projekty/Harmony/elixir
echo "=== LiveView usage in lib ==="; grep -rn "Phoenix.LiveView\|LiveView\|live(\|fetch_live_flash\|put_root_layout\|DashboardLive\|ProjectsLive\|ProjectFormLive\|Layouts" lib | sort
echo "=== LiveView/legacy usage in tests ==="; grep -rn "Phoenix.LiveViewTest\|live(\|DashboardLive\|ProjectsLive\|ProjectFormLive\|/projects\|dashboard.css\|/vendor/" test | sort
echo "=== legacy asset routes ==="; grep -rn "StaticAsset\|dashboard.css\|/vendor/" lib
echo "=== e2e harness LiveView coupling ==="; grep -rn "LiveView\|phx-\|liveSocket\|/live" lib/symphony_elixir/roadmap_e2e.ex lib/mix/tasks/harmony.roadmap_e2e.ex test/symphony_elixir/roadmap_e2e_harness_test.exs test/symphony_elixir/live_e2e_test.exs 2>/dev/null
```

Expected: a list of every file to edit in this phase. Record it; the tasks below cover each category. If new couplings appear that are not covered, add a task before proceeding.

- [ ] **Step 2: Commit nothing (discovery).** Proceed to Task 2.

---

### Task 2: Flip the SPA to the root path

**Files:**
- Modify: `elixir/assets/vite.config.ts`
- Modify: `elixir/lib/symphony_elixir_web/controllers/spa_controller.ex` (no code change if it already reads `priv/static/app/index.html`; verify)

- [ ] **Step 1: Set `base: "/"` in `vite.config.ts`**

Change the `base` field:

```ts
  base: "/",
```

(`main.tsx` already derives `basename` from `import.meta.env.BASE_URL`, so it becomes `""` automatically — no change needed there.)

- [ ] **Step 2: Rebuild**

```bash
cd /work/Projekty/Harmony/elixir/assets
npm run build && head -5 ../priv/static/app/index.html
```

Expected: asset URLs in `index.html` now start with `/assets/...` (not `/app/assets/...`).

- [ ] **Step 3: Commit**

```bash
cd /work/Projekty/Harmony
git add elixir/assets/vite.config.ts
git commit -m "build(assets): serve SPA from root base path"
```

---

### Task 3: Serve the SPA at `/` and remove the `/live` socket

**Files:**
- Modify: `elixir/lib/symphony_elixir_web/endpoint.ex`
- Modify: `elixir/test/symphony_elixir/spa_serving_test.exs`

- [ ] **Step 1: Update the failing test to expect SPA at `/`**

Edit `elixir/test/symphony_elixir/spa_serving_test.exs` so the two requests use root paths:

```elixir
  test "GET / returns the SPA index.html" do
    conn = get(build_conn(), "/")

    assert conn.status == 200
    assert get_resp_header(conn, "content-type") |> List.first() =~ "text/html"
    assert conn.resp_body =~ "<div id=\"root\">"
  end

  test "GET a client-side route returns index.html (SPA fallback)" do
    conn = get(build_conn(), "/projects/new")

    assert conn.status == 200
    assert conn.resp_body =~ "<div id=\"root\">"
  end
```

- [ ] **Step 2: Run it to verify it fails**

```bash
cd /work/Projekty/Harmony/elixir
mix test test/symphony_elixir/spa_serving_test.exs
```

Expected: FAIL — `/` is still the LiveView (or 200 with LiveView HTML, not `#root`).

- [ ] **Step 3: Update `Plug.Static` to serve at root and remove the `/live` socket**

In `elixir/lib/symphony_elixir_web/endpoint.ex`:

Change the `Plug.Static` `at:` from `"/app"` to `"/"`:

```elixir
  plug(Plug.Static,
    at: "/",
    from: {:symphony_elixir, "priv/static/app"},
    gzip: false,
    only: ~w(assets index.html favicon.ico vite.svg)
  )
```

Delete the `socket("/live", Phoenix.LiveView.Socket, ...)` block. Keep the `socket("/socket", SymphonyElixirWeb.UserSocket, ...)` block from Phase 1.

- [ ] **Step 4: Run the test (it will still fail until the router is updated in Task 4).** Proceed to Task 4; run both tests there.

---

### Task 4: Rewrite the router (remove LiveView, add root SPA fallback)

**Files:**
- Modify: `elixir/lib/symphony_elixir_web/router.ex`

- [ ] **Step 1: Replace the router with the SPA-only version**

`elixir/lib/symphony_elixir_web/router.ex`:

```elixir
defmodule SymphonyElixirWeb.Router do
  @moduledoc """
  Router for Symphony's JSON API, realtime socket, and the React SPA.
  """

  use Phoenix.Router

  pipeline :browser do
    plug(:fetch_session)
    plug(:protect_from_forgery)
    plug(:put_secure_browser_headers)
  end

  scope "/", SymphonyElixirWeb do
    get("/api/v1/state", ObservabilityApiController, :state)
    match(:*, "/api/v1/state", ObservabilityApiController, :method_not_allowed)
    post("/api/v1/refresh", ObservabilityApiController, :refresh)
    match(:*, "/api/v1/refresh", ObservabilityApiController, :method_not_allowed)
    post("/api/v1/github/webhook", GithubWebhookController, :create)
    match(:*, "/api/v1/github/webhook", ObservabilityApiController, :method_not_allowed)

    get("/api/v1/projects", ProjectController, :index)
    post("/api/v1/projects", ProjectController, :create)
    get("/api/v1/projects/:id", ProjectController, :show)
    put("/api/v1/projects/:id", ProjectController, :update)
    patch("/api/v1/projects/:id", ProjectController, :update)

    get("/api/v1/:issue_identifier", ObservabilityApiController, :issue)
    match(:*, "/api/v1/:issue_identifier", ObservabilityApiController, :method_not_allowed)
    match(:*, "/api/*path", ObservabilityApiController, :not_found)
  end

  # SPA fallback: any non-API GET serves the React index.html. Declared last so it
  # cannot shadow the API routes or the /socket transport.
  scope "/", SymphonyElixirWeb do
    pipe_through(:browser)

    get("/", SpaController, :index)
    get("/*path", SpaController, :index)
  end
end
```

> Removed: `import Phoenix.LiveView.Router`, `plug(:fetch_live_flash)`, `plug(:put_root_layout, ...)`, all `live(...)` routes, and the `/dashboard.css` + `/vendor/...` static-asset routes. The non-GET catch-all is now scoped to `/api/*path` so the SPA fallback owns all other GETs.

- [ ] **Step 2: Run the SPA serving test to verify it passes**

```bash
cd /work/Projekty/Harmony/elixir
mix test test/symphony_elixir/spa_serving_test.exs
```

Expected: 2 passing tests (SPA served at `/`).

- [ ] **Step 3: Commit (compilation will still warn about deleted modules until Task 5; that is fine — but the LiveView modules are still present here, so it compiles).**

```bash
cd /work/Projekty/Harmony
git add elixir/lib/symphony_elixir_web/endpoint.ex elixir/lib/symphony_elixir_web/router.ex elixir/test/symphony_elixir/spa_serving_test.exs
git commit -m "feat(web): serve React SPA at / and drop the LiveView socket"
```

---

### Task 5: Delete LiveView modules, layout, and the legacy asset pipeline

**Files (delete):**
- `elixir/lib/symphony_elixir_web/live/dashboard_live.ex`
- `elixir/lib/symphony_elixir_web/live/projects_live.ex`
- `elixir/lib/symphony_elixir_web/live/project_form_live.ex`
- `elixir/lib/symphony_elixir_web/components/layouts.ex`
- `elixir/lib/symphony_elixir_web/controllers/static_asset_controller.ex`
- `elixir/lib/symphony_elixir_web/static_assets.ex`
- `elixir/priv/static/dashboard.css`
- `elixir/test/symphony_elixir/project_ui_test.exs` (LiveView UI test, superseded by `project_api_test.exs` + Vitest)

- [ ] **Step 1: Delete the files**

```bash
cd /work/Projekty/Harmony/elixir
git rm lib/symphony_elixir_web/live/dashboard_live.ex \
       lib/symphony_elixir_web/live/projects_live.ex \
       lib/symphony_elixir_web/live/project_form_live.ex \
       lib/symphony_elixir_web/components/layouts.ex \
       lib/symphony_elixir_web/controllers/static_asset_controller.ex \
       lib/symphony_elixir_web/static_assets.ex \
       priv/static/dashboard.css \
       test/symphony_elixir/project_ui_test.exs
rmdir lib/symphony_elixir_web/live 2>/dev/null || true
```

- [ ] **Step 2: Compile to find dangling references**

```bash
mix compile 2>&1 | tee /tmp/compile.out
```

Expected: errors only point at the `:phoenix_live_view` compiler and any remaining references (handled in Task 6). If any non-LiveView module referenced a deleted one, fix that reference now (e.g., remove `alias SymphonyElixirWeb.Layouts`).

- [ ] **Step 3: Commit**

```bash
cd /work/Projekty/Harmony
git add -A elixir/lib elixir/priv elixir/test
git commit -m "refactor(web): remove LiveView UI and legacy asset pipeline"
```

---

### Task 6: Drop the phoenix_live_view dependency + compiler

**Files:**
- Modify: `elixir/mix.exs`

- [ ] **Step 1: Remove the LiveView compiler**

In `elixir/mix.exs` `project/0`, change:

```elixir
compilers: [:phoenix_live_view] ++ Mix.compilers(),
```

to:

```elixir
compilers: Mix.compilers(),
```

- [ ] **Step 2: Remove the dependency**

Delete this line from `deps/0`:

```elixir
{:phoenix_live_view, "~> 1.1.0"},
```

Also remove `{:lazy_html, ...}` and `{:floki, ...}` ONLY if the grep in Task 1 showed they are no longer used in tests (they back `Phoenix.LiveViewTest`). If any remaining test uses Floki/LazyHtml, keep them.

- [ ] **Step 3: Clean the coverage ignore list**

In the `test_coverage` `ignore_modules` list, remove entries for deleted modules: `SymphonyElixirWeb.DashboardLive`, `SymphonyElixirWeb.Layouts`, `SymphonyElixirWeb.StaticAssetController`, `SymphonyElixirWeb.StaticAssets`. (Leave the others.)

- [ ] **Step 4: Refetch deps and compile**

```bash
cd /work/Projekty/Harmony/elixir
mix deps.get
mix compile --warnings-as-errors
```

Expected: compiles with no LiveView references.

- [ ] **Step 5: Full test run**

```bash
mix test
```

Expected: all pass (LiveView-only test already removed). If a test still imports `Phoenix.LiveViewTest`, remove or rewrite it to hit the JSON API / SPA controller instead.

- [ ] **Step 6: Commit**

```bash
cd /work/Projekty/Harmony
git add elixir/mix.exs elixir/mix.lock
git commit -m "chore(deps): drop phoenix_live_view after React cutover"
```

---

### Task 7: Repoint the Playwright e2e harness at the SPA

**Files:**
- Modify: `elixir/lib/symphony_elixir/roadmap_e2e.ex` and/or `elixir/lib/mix/tasks/harmony.roadmap_e2e.ex` and the harness test, per the Task 1 grep.

- [ ] **Step 1: Identify LiveView-coupled selectors/flows**

Using the Task 1 grep output for the harness files, find any assertions that depend on LiveView markup (e.g., `phx-` attributes, the `liveSocket`, `data-phx-*`, or the old root layout title "Symphony Observability").

- [ ] **Step 2: Update selectors to the SPA DOM**

Replace LiveView-specific waits/selectors with SPA equivalents:
- Wait for `#root` to be populated and the dashboard heading `Dashboard` to be visible.
- For projects, navigate to `/projects` and assert the table rendered by `ProjectsPage`.
- The dashboard updates without reload — assert content changes after `POST /api/v1/refresh` rather than waiting for a LiveView patch.

> If the harness builds assets, ensure it runs `mix assets.build` (or that `priv/static/app/index.html` exists) before launching Chrome.

- [ ] **Step 3: Run the e2e harness**

```bash
cd /work/Projekty/Harmony/elixir
make e2e
```

Expected: the harness drives the React UI at `/` and exits 0. (If Playwright/Chrome is unavailable locally, record the exact failure; the harness is the gate to run where browsers are available.)

- [ ] **Step 4: Commit**

```bash
cd /work/Projekty/Harmony
git add -A elixir/lib elixir/test
git commit -m "test(e2e): drive the React SPA in the roadmap e2e harness"
```

---

### Task 8: Docs + final validation

**Files:**
- Modify: `README.md`, `docs/harmony-operations.md` (only where they describe the LiveView dashboard / asset serving)

- [ ] **Step 1: Update docs that mention the LiveView dashboard**

```bash
cd /work/Projekty/Harmony
grep -rn "LiveView\|dashboard.css\|/vendor/\|liveSocket" README.md docs/harmony-operations.md
```

Update any matched lines to describe the React SPA built via `mix assets.build` and served from `priv/static/app`. If there are no matches, skip.

- [ ] **Step 2: Run the full backend CI gate**

```bash
cd /work/Projekty/Harmony/elixir
make all
```

Expected: exits 0. (If local Postgres/Dialyzer/Chrome are unavailable, record the exact failures and run the targeted non-DB suites.)

- [ ] **Step 3: Run the full frontend gate**

```bash
cd /work/Projekty/Harmony/elixir/assets
npm run lint && npm run test -- --run && npm run build
```

Expected: all exit 0.

- [ ] **Step 4: Commit any doc changes**

```bash
cd /work/Projekty/Harmony
git add README.md docs/harmony-operations.md 2>/dev/null || true
git commit -m "docs: describe the React SPA frontend" || true
```

---

## Phase 3 Final Validation

- [ ] `GET /` serves the React SPA (covered by `spa_serving_test.exs`).
- [ ] `GET /api/v1/state`, `/api/v1/projects`, the `/socket` channel, and `POST /api/v1/github/webhook` all still work (covered by existing tests).
- [ ] No `phoenix_live_view` in `mix.lock`; `mix compile --warnings-as-errors` passes.
- [ ] No `lib/symphony_elixir_web/live/` directory; no `dashboard.css`; no `/vendor/...` routes.
- [ ] `make all` exits 0 (or failures recorded with reasons).
- [ ] e2e harness drives the SPA (or recorded as browser-unavailable).

## Goal Complete

With Phase 3 merged, the React + WebSockets frontend fully replaces LiveView: the SPA is served at `/`, the dashboard is live over the channel, projects are managed over REST, and LiveView is gone.
