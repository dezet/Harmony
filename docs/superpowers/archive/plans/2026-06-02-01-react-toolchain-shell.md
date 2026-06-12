# Phase 0 — React Toolchain + App Shell Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stand up a Vite + TypeScript + React app under `elixir/assets/`, build it into `elixir/priv/static/app/`, and serve it from Phoenix under `/app` (LiveView stays the default at `/`), with Tailwind + shadcn/ui, React Router, a Vitest harness, dev proxy, build aliases, and frontend agent docs.

**Architecture:** Additive only. No existing LiveView, route, or asset module is removed. The SPA mounts at `/app` via a new `Plug.Static` (serving `priv/static/app`) plus a `SpaController` that returns `index.html` for client-side routes. Vite builds with `base: '/app/'` so asset URLs resolve under `/app`.

**Tech Stack:** Vite 5, React 18, TypeScript 5, React Router v6, Tailwind 3, shadcn/ui, Vitest 2 + React Testing Library, Elixir/Phoenix (`Plug.Static`, controller), ExUnit.

**Prereqs:** Node.js ≥ 20 and npm available on the machine. Run all `npm` commands from `elixir/assets/`. Run all `mix` commands from `elixir/`.

---

## File Structure

- Create: `elixir/assets/` — Vite app root (scaffolded).
- Create: `elixir/assets/vite.config.ts`, `tsconfig*.json`, `tailwind.config.ts`, `postcss.config.js`, `components.json`.
- Create: `elixir/assets/src/main.tsx`, `src/App.tsx`, `src/routes/*`, `src/components/layout/AppShell.tsx`, `src/components/ui/*` (shadcn), `src/test/setup.ts`.
- Create: `elixir/assets/CLAUDE.md`, `elixir/assets/AGENTS.md`.
- Create: `elixir/lib/symphony_elixir_web/controllers/spa_controller.ex`.
- Create: `elixir/test/symphony_elixir/spa_serving_test.exs`.
- Modify: `elixir/lib/symphony_elixir_web/endpoint.ex` (add `Plug.Static`).
- Modify: `elixir/lib/symphony_elixir_web/router.ex` (add `/app` routes).
- Modify: `elixir/mix.exs` (aliases), `elixir/Makefile` (assets target), `elixir/.gitignore`.

---

### Task 1: Scaffold the Vite + React + TS app

**Files:**
- Create: `elixir/assets/**` (Vite scaffold)

- [ ] **Step 1: Scaffold with the official template**

Run from `elixir/`:

```bash
npm create vite@latest assets -- --template react-ts
```

Expected: creates `elixir/assets/` with `package.json`, `index.html`, `src/main.tsx`, `src/App.tsx`, `tsconfig*.json`, `vite.config.ts`.

- [ ] **Step 2: Install base + runtime dependencies**

Run from `elixir/assets/`:

```bash
npm install
npm install react-router-dom @tanstack/react-query phoenix react-hook-form @hookform/resolvers yup
npm install -D @types/phoenix vitest jsdom @testing-library/react @testing-library/jest-dom @testing-library/user-event @vitejs/plugin-react
```

Expected: all install without error; `package.json` lists the dependencies.

- [ ] **Step 3: Verify the scaffold builds**

Run from `elixir/assets/`:

```bash
npm run build
```

Expected: exits 0 and writes a `dist/` directory (relocated in Task 2).

- [ ] **Step 4: Commit**

```bash
cd /work/Projekty/Harmony
git add elixir/assets
git commit -m "feat(frontend): scaffold Vite + React + TypeScript app"
```

---

### Task 2: Configure Vite output, base path, and gitignore

**Files:**
- Modify: `elixir/assets/vite.config.ts`
- Modify: `elixir/.gitignore`

- [ ] **Step 1: Replace `vite.config.ts`**

```ts
import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";
import path from "node:path";

// The SPA is served by Phoenix from priv/static/app under the /app base path
// during Phases 0-2. Phase 3 flips `base` to "/".
export default defineConfig({
  base: "/app/",
  plugins: [react()],
  resolve: {
    alias: { "@": path.resolve(__dirname, "./src") },
  },
  build: {
    outDir: "../priv/static/app",
    emptyOutDir: true,
  },
  test: {
    environment: "jsdom",
    globals: true,
    setupFiles: "./src/test/setup.ts",
    css: true,
  },
});
```

- [ ] **Step 2: Add path alias to `tsconfig.json`**

Add to the `compilerOptions` of `elixir/assets/tsconfig.json` (or `tsconfig.app.json` if the scaffold split configs — add to whichever holds `compilerOptions` for `src`):

```json
"baseUrl": ".",
"paths": { "@/*": ["./src/*"] }
```

- [ ] **Step 3: Ignore node_modules and the build output**

Append to `elixir/.gitignore`:

```
# React frontend
/assets/node_modules
/priv/static/app
```

- [ ] **Step 4: Verify build writes to priv/static/app**

Run from `elixir/assets/`:

```bash
npm run build && ls ../priv/static/app/index.html
```

Expected: `../priv/static/app/index.html` exists.

- [ ] **Step 5: Commit**

```bash
cd /work/Projekty/Harmony
git add elixir/assets/vite.config.ts elixir/assets/tsconfig.json elixir/.gitignore
git commit -m "feat(frontend): build Vite app to priv/static/app under /app base"
```

---

### Task 3: Vitest harness

**Files:**
- Create: `elixir/assets/src/test/setup.ts`
- Create: `elixir/assets/src/test/smoke.test.tsx`
- Modify: `elixir/assets/package.json` (scripts)

- [ ] **Step 1: Create the test setup file**

`elixir/assets/src/test/setup.ts`:

```ts
import "@testing-library/jest-dom";
```

- [ ] **Step 2: Add npm scripts**

In `elixir/assets/package.json`, ensure `scripts` contains:

```json
"dev": "vite",
"build": "tsc -b && vite build",
"preview": "vite preview",
"test": "vitest",
"lint": "tsc -b --noEmit"
```

(The scaffold ships `lint` as eslint; replacing it with `tsc --noEmit` keeps the toolchain minimal. Keep eslint too if the scaffold configured it.)

- [ ] **Step 3: Write a failing smoke test**

`elixir/assets/src/test/smoke.test.tsx`:

```tsx
import { render, screen } from "@testing-library/react";
import { describe, it, expect } from "vitest";

function Hello() {
  return <h1>Harmony</h1>;
}

describe("vitest harness", () => {
  it("renders a component", () => {
    render(<Hello />);
    expect(screen.getByRole("heading", { name: "Harmony" })).toBeInTheDocument();
  });
});
```

- [ ] **Step 4: Run the test**

Run from `elixir/assets/`:

```bash
npm run test -- --run
```

Expected: 1 passing test. (If `toBeInTheDocument` is unknown, the setup file in Step 1 is not wired — re-check `setupFiles` in `vite.config.ts`.)

- [ ] **Step 5: Commit**

```bash
cd /work/Projekty/Harmony
git add elixir/assets/src/test elixir/assets/package.json
git commit -m "test(frontend): add Vitest + RTL harness"
```

---

### Task 4: Tailwind + shadcn/ui

**Files:**
- Create: `elixir/assets/tailwind.config.ts`, `postcss.config.js`, `components.json`, `src/index.css` (or replace scaffold CSS)
- Create: `elixir/assets/src/lib/utils.ts`, `src/components/ui/button.tsx` (via shadcn CLI)

- [ ] **Step 1: Install and init Tailwind**

Run from `elixir/assets/`:

```bash
npm install -D tailwindcss postcss autoprefixer
npx tailwindcss init -p
```

Expected: creates `tailwind.config.js` and `postcss.config.js`.

- [ ] **Step 2: Configure Tailwind content + base CSS**

Replace `elixir/assets/tailwind.config.js` content globs:

```js
/** @type {import('tailwindcss').Config} */
export default {
  content: ["./index.html", "./src/**/*.{ts,tsx}"],
  theme: { extend: {} },
  plugins: [],
};
```

Replace `elixir/assets/src/index.css` with the Tailwind directives:

```css
@tailwind base;
@tailwind components;
@tailwind utilities;
```

Ensure `src/main.tsx` imports `./index.css`.

- [ ] **Step 3: Initialize shadcn/ui**

Run from `elixir/assets/` and accept defaults (default style, default base color, CSS variables yes):

```bash
npx shadcn@latest init
```

Expected: creates `components.json`, `src/lib/utils.ts`, and updates `tailwind.config`/`index.css` with the shadcn theme tokens. shadcn uses the `@/*` alias from Task 2.

- [ ] **Step 4: Add the Button primitive to verify the CLI**

Run from `elixir/assets/`:

```bash
npx shadcn@latest add button
```

Expected: creates `src/components/ui/button.tsx`.

- [ ] **Step 5: Write a test that renders the shadcn Button**

`elixir/assets/src/components/ui/button.test.tsx`:

```tsx
import { render, screen } from "@testing-library/react";
import { describe, it, expect } from "vitest";
import { Button } from "@/components/ui/button";

describe("shadcn Button", () => {
  it("renders its children", () => {
    render(<Button>Refresh</Button>);
    expect(screen.getByRole("button", { name: "Refresh" })).toBeInTheDocument();
  });
});
```

- [ ] **Step 6: Run tests and build**

Run from `elixir/assets/`:

```bash
npm run test -- --run && npm run build
```

Expected: tests pass; build exits 0.

- [ ] **Step 7: Commit**

```bash
cd /work/Projekty/Harmony
git add elixir/assets
git commit -m "feat(frontend): add Tailwind + shadcn/ui with default theme"
```

---

### Task 5: React Router skeleton + app shell

**Files:**
- Create: `elixir/assets/src/components/layout/AppShell.tsx`
- Create: `elixir/assets/src/routes/DashboardPage.tsx`, `ProjectsPage.tsx`, `ProjectFormPage.tsx`, `NotFoundPage.tsx`
- Modify: `elixir/assets/src/App.tsx`, `src/main.tsx`
- Create: `elixir/assets/src/App.test.tsx`

- [ ] **Step 1: Write a failing routing test**

`elixir/assets/src/App.test.tsx`:

```tsx
import { render, screen } from "@testing-library/react";
import { MemoryRouter } from "react-router-dom";
import { describe, it, expect } from "vitest";
import { AppRoutes } from "@/App";

function renderAt(path: string) {
  return render(
    <MemoryRouter initialEntries={[path]}>
      <AppRoutes />
    </MemoryRouter>,
  );
}

describe("AppRoutes", () => {
  it("shows the nav and the dashboard at /", () => {
    renderAt("/");
    expect(screen.getByRole("navigation")).toBeInTheDocument();
    expect(screen.getByRole("heading", { name: /dashboard/i })).toBeInTheDocument();
  });

  it("shows the projects page at /projects", () => {
    renderAt("/projects");
    expect(screen.getByRole("heading", { name: /projects/i })).toBeInTheDocument();
  });

  it("shows a not-found page for unknown routes", () => {
    renderAt("/nope");
    expect(screen.getByText(/not found/i)).toBeInTheDocument();
  });
});
```

- [ ] **Step 2: Run the test to verify it fails**

```bash
npm run test -- --run src/App.test.tsx
```

Expected: FAIL — `AppRoutes` is not exported / files missing.

- [ ] **Step 3: Create the placeholder pages**

`src/routes/DashboardPage.tsx`:

```tsx
export function DashboardPage() {
  return <h1 className="text-2xl font-semibold">Dashboard</h1>;
}
```

`src/routes/ProjectsPage.tsx`:

```tsx
export function ProjectsPage() {
  return <h1 className="text-2xl font-semibold">Projects</h1>;
}
```

`src/routes/ProjectFormPage.tsx`:

```tsx
export function ProjectFormPage() {
  return <h1 className="text-2xl font-semibold">Project form</h1>;
}
```

`src/routes/NotFoundPage.tsx`:

```tsx
export function NotFoundPage() {
  return <p>Not found</p>;
}
```

- [ ] **Step 4: Create the app shell**

`src/components/layout/AppShell.tsx`:

```tsx
import { Link, Outlet } from "react-router-dom";

export function AppShell() {
  return (
    <div className="min-h-screen bg-background text-foreground">
      <nav className="border-b px-6 py-3 flex gap-4">
        <Link to="/">Dashboard</Link>
        <Link to="/projects">Projects</Link>
      </nav>
      <main className="p-6">
        <Outlet />
      </main>
    </div>
  );
}
```

- [ ] **Step 5: Define routes in `App.tsx`**

`src/App.tsx`:

```tsx
import { Routes, Route } from "react-router-dom";
import { AppShell } from "@/components/layout/AppShell";
import { DashboardPage } from "@/routes/DashboardPage";
import { ProjectsPage } from "@/routes/ProjectsPage";
import { ProjectFormPage } from "@/routes/ProjectFormPage";
import { NotFoundPage } from "@/routes/NotFoundPage";

export function AppRoutes() {
  return (
    <Routes>
      <Route element={<AppShell />}>
        <Route index element={<DashboardPage />} />
        <Route path="projects" element={<ProjectsPage />} />
        <Route path="projects/new" element={<ProjectFormPage />} />
        <Route path="projects/:id/edit" element={<ProjectFormPage />} />
        <Route path="*" element={<NotFoundPage />} />
      </Route>
    </Routes>
  );
}
```

- [ ] **Step 6: Wire the router + base path in `main.tsx`**

`src/main.tsx`:

```tsx
import React from "react";
import ReactDOM from "react-dom/client";
import { BrowserRouter } from "react-router-dom";
import { AppRoutes } from "@/App";
import "./index.css";

// import.meta.env.BASE_URL is "/app/" in Phases 0-2, "/" after Phase 3.
const basename = import.meta.env.BASE_URL.replace(/\/$/, "");

ReactDOM.createRoot(document.getElementById("root")!).render(
  <React.StrictMode>
    <BrowserRouter basename={basename}>
      <AppRoutes />
    </BrowserRouter>
  </React.StrictMode>,
);
```

- [ ] **Step 7: Run the test to verify it passes**

```bash
npm run test -- --run src/App.test.tsx
```

Expected: 3 passing tests.

- [ ] **Step 8: Commit**

```bash
cd /work/Projekty/Harmony
git add elixir/assets/src
git commit -m "feat(frontend): add React Router skeleton and app shell"
```

---

### Task 6: Serve the SPA from Phoenix under /app

**Files:**
- Modify: `elixir/lib/symphony_elixir_web/endpoint.ex`
- Modify: `elixir/lib/symphony_elixir_web/router.ex`
- Create: `elixir/lib/symphony_elixir_web/controllers/spa_controller.ex`
- Create: `elixir/test/symphony_elixir/spa_serving_test.exs`

- [ ] **Step 1: Build the assets so there is something to serve**

Run from `elixir/assets/`:

```bash
npm run build
```

Expected: `elixir/priv/static/app/index.html` exists.

- [ ] **Step 2: Write a failing controller test**

`elixir/test/symphony_elixir/spa_serving_test.exs`:

```elixir
defmodule SymphonyElixir.SpaServingTest do
  use SymphonyElixir.TestSupport

  import Phoenix.ConnTest

  @endpoint SymphonyElixirWeb.Endpoint

  setup do
    start_test_endpoint()
    :ok
  end

  test "GET /app returns the SPA index.html" do
    conn = get(build_conn(), "/app")

    assert conn.status == 200
    assert get_resp_header(conn, "content-type") |> List.first() =~ "text/html"
    assert conn.resp_body =~ "<div id=\"root\">"
  end

  test "GET a client-side route returns index.html (SPA fallback)" do
    conn = get(build_conn(), "/app/projects/new")

    assert conn.status == 200
    assert conn.resp_body =~ "<div id=\"root\">"
  end

  defp start_test_endpoint do
    endpoint_config =
      :symphony_elixir
      |> Application.get_env(SymphonyElixirWeb.Endpoint, [])
      |> Keyword.merge(server: false, secret_key_base: String.duplicate("s", 64))

    Application.put_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, endpoint_config)
    start_supervised!({SymphonyElixirWeb.Endpoint, []})
  end
end
```

- [ ] **Step 3: Run it to verify it fails**

```bash
cd /work/Projekty/Harmony/elixir
mix test test/symphony_elixir/spa_serving_test.exs
```

Expected: FAIL — `/app` is not routed (404 / no match).

- [ ] **Step 4: Add `Plug.Static` to the endpoint**

In `elixir/lib/symphony_elixir_web/endpoint.ex`, add immediately after `use Phoenix.Endpoint, otp_app: :symphony_elixir` and before the existing `socket(...)` call:

```elixir
  plug(Plug.Static,
    at: "/app",
    from: {:symphony_elixir, "priv/static/app"},
    gzip: false,
    only: ~w(assets index.html favicon.ico vite.svg)
  )
```

- [ ] **Step 5: Create the SPA fallback controller**

`elixir/lib/symphony_elixir_web/controllers/spa_controller.ex`:

```elixir
defmodule SymphonyElixirWeb.SpaController do
  @moduledoc """
  Serves the React SPA's index.html for client-side routes under /app.
  """

  use Phoenix.Controller, formats: [:html]

  @index_path Path.join(:code.priv_dir(:symphony_elixir), "static/app/index.html")

  @spec index(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def index(conn, _params) do
    case File.read(@index_path) do
      {:ok, body} ->
        conn
        |> Plug.Conn.put_resp_content_type("text/html")
        |> Plug.Conn.send_resp(200, body)

      {:error, _reason} ->
        conn
        |> Plug.Conn.put_resp_content_type("text/html")
        |> Plug.Conn.send_resp(503, "SPA not built. Run: mix assets.build")
    end
  end
end
```

> Note: `@index_path` resolves at compile time, which is correct for releases. The `File.read/1` happens per request so a rebuilt `index.html` is picked up without recompiling.

- [ ] **Step 6: Route `/app` to the SPA controller**

In `elixir/lib/symphony_elixir_web/router.ex`, add a new scope BEFORE the final API catch-all scope (so it does not get shadowed), inside the file but after the `:browser` pipeline scope:

```elixir
  scope "/app", SymphonyElixirWeb do
    pipe_through(:browser)

    get("/", SpaController, :index)
    get("/*path", SpaController, :index)
  end
```

- [ ] **Step 7: Run the test to verify it passes**

```bash
cd /work/Projekty/Harmony/elixir
mix test test/symphony_elixir/spa_serving_test.exs
```

Expected: 2 passing tests.

- [ ] **Step 8: Format, full test run, commit**

```bash
cd /work/Projekty/Harmony/elixir
mix format
mix test
cd /work/Projekty/Harmony
git add elixir/lib/symphony_elixir_web/endpoint.ex elixir/lib/symphony_elixir_web/router.ex elixir/lib/symphony_elixir_web/controllers/spa_controller.ex elixir/test/symphony_elixir/spa_serving_test.exs
git commit -m "feat(web): serve React SPA from Phoenix under /app"
```

---

### Task 7: Mix aliases + Makefile target for assets

**Files:**
- Modify: `elixir/mix.exs`
- Modify: `elixir/Makefile`

- [ ] **Step 1: Add asset aliases in `mix.exs`**

Replace the `aliases/0` function in `elixir/mix.exs` with:

```elixir
  defp aliases do
    [
      setup: ["deps.get", "assets.setup"],
      build: ["escript.build"],
      lint: ["specs.check", "credo --strict"],
      "assets.setup": ["cmd --cd assets npm ci"],
      "assets.build": ["cmd --cd assets npm run build"]
    ]
  end
```

> `assets.setup` uses `npm ci` (clean, lockfile-based). On a fresh checkout with no `package-lock.json` yet, run `npm install` once in `assets/` to generate the lockfile, then commit it.

- [ ] **Step 2: Add a Makefile `assets` target**

In `elixir/Makefile`, add `assets` to `.PHONY` and add the target:

```makefile
assets:
	$(MIX) assets.build
```

- [ ] **Step 3: Verify the alias builds assets**

```bash
cd /work/Projekty/Harmony/elixir
mix assets.build && ls priv/static/app/index.html
```

Expected: build runs via npm and `priv/static/app/index.html` exists.

- [ ] **Step 4: Commit the lockfile + aliases**

```bash
cd /work/Projekty/Harmony
git add elixir/mix.exs elixir/Makefile elixir/assets/package-lock.json
git commit -m "build(assets): add mix assets.setup/assets.build aliases and Makefile target"
```

---

### Task 8: Vite dev server proxy

**Files:**
- Modify: `elixir/assets/vite.config.ts`

- [ ] **Step 1: Find the Phoenix dev port**

```bash
cd /work/Projekty/Harmony/elixir
mix run -e 'IO.puts(SymphonyElixir.Config.server_port())'
```

Expected: prints the configured port (used as the proxy target below; substitute it for `PORT` in Step 2 if it is not the value shown).

- [ ] **Step 2: Add a proxy block to `vite.config.ts`**

Add a `server` key to the config object in `elixir/assets/vite.config.ts`. Use the port from Step 1 (read from an env var with a sensible default so the value is not hardcoded):

```ts
  server: {
    proxy: {
      "/api": { target: `http://localhost:${process.env.HARMONY_PORT ?? "4000"}`, changeOrigin: true },
      "/socket": {
        target: `http://localhost:${process.env.HARMONY_PORT ?? "4000"}`,
        ws: true,
        changeOrigin: true,
      },
    },
  },
```

> If Step 1 printed a port other than 4000, run the dev server with `HARMONY_PORT=<that port> npm run dev`.

- [ ] **Step 3: Verify the dev server starts**

Run from `elixir/assets/`:

```bash
timeout 8 npm run dev || true
```

Expected: Vite prints "Local: http://localhost:5173/app/" then exits on the timeout. (The proxy is exercised manually with Phoenix running; no automated test here.)

- [ ] **Step 4: Commit**

```bash
cd /work/Projekty/Harmony
git add elixir/assets/vite.config.ts
git commit -m "build(assets): proxy /api and /socket to Phoenix in dev"
```

---

### Task 9: Frontend agent docs

**Files:**
- Create: `elixir/assets/CLAUDE.md`
- Create: `elixir/assets/AGENTS.md`

- [ ] **Step 1: Write `elixir/assets/CLAUDE.md`**

```markdown
# Harmony Frontend (React) — Agent Guide

This is the React SPA for Harmony. Backend is Elixir/Phoenix in the parent directory.

## Stack
- TypeScript + Vite (root: `elixir/assets`, builds to `elixir/priv/static/app`)
- React Router v6 (routes in `src/App.tsx`)
- React Query (TanStack Query v5) — the single client-side source of truth
- Phoenix Channels via the `phoenix` npm client — live data hydrates the React Query cache
- React Hook Form + Yup for forms
- shadcn/ui + Tailwind (default theme)
- Vitest + React Testing Library

## Conventions
- `src/components/ui/*` are generated by the shadcn CLI. Do not hand-edit them.
- Before writing a custom component, check whether shadcn provides one: `npx shadcn@latest add <name>`.
- Lean on the default shadcn theme. Avoid ad-hoc CSS; use Tailwind utilities.
- No `fetch` in components. All HTTP goes through `src/lib/api.ts` + React Query hooks. Live data comes through the Channel hook in `src/lib/socket.ts`.
- The wire contract (server payload shapes) lives in `src/types/contract.ts`. Keep it in sync with `SymphonyElixirWeb.Presenter`.
- Feature code lives under `src/features/<feature>/` or `src/routes/`. Files that change together live together.

## Run
- Dev: start Phoenix (the server boots via the OTP app), then `npm run dev` here (proxies `/api` and `/socket`). Open http://localhost:5173/app/.
- Tests: `npm run test -- --run`
- Build: from `elixir/`, `mix assets.build` (or `npm run build` here).

## Routing note
During Phases 0-2 the app is served under `/app` (`base: "/app/"`). Phase 3 flips `base` to `/`.
```

- [ ] **Step 2: Write `elixir/assets/AGENTS.md`**

```markdown
# Harmony Frontend — Agent Notes (Codex/others)

See `CLAUDE.md` in this directory for the full guide. Summary:

- React + TypeScript SPA built by Vite into `../priv/static/app`, served by Phoenix.
- Data: React Query for REST (`src/lib/api.ts`), Phoenix Channels for live dashboard data (`src/lib/socket.ts`) hydrating the React Query cache.
- Forms: React Hook Form + Yup. UI: shadcn/ui (default theme) + Tailwind.
- `src/components/ui/*` is shadcn-generated; do not hand-edit. Check shadcn before writing a custom component.
- Wire contract types: `src/types/contract.ts`, mirroring `SymphonyElixirWeb.Presenter`.
- Tests: Vitest + RTL (`npm run test -- --run`). Build: `mix assets.build` from `elixir/`.
```

- [ ] **Step 3: Commit**

```bash
cd /work/Projekty/Harmony
git add elixir/assets/CLAUDE.md elixir/assets/AGENTS.md
git commit -m "docs(frontend): add CLAUDE.md and AGENTS.md conventions"
```

---

## Phase 0 Final Validation

- [ ] From `elixir/assets/`: `npm run lint && npm run test -- --run && npm run build` all exit 0.
- [ ] From `elixir/`: `mix format --check-formatted && mix test` exit 0.
- [ ] `GET /app` returns the SPA `index.html` (covered by `spa_serving_test.exs`).
- [ ] `/` still serves the existing LiveView dashboard (unchanged). Confirm: `mix test test/symphony_elixir/project_ui_test.exs` still passes.
- [ ] Commit any formatting fixups.

## Self-Review Notes (carry into Phase 1)
- The SPA shell renders placeholder pages only. Phase 1 replaces `DashboardPage` with the live dashboard.
- `src/lib/`, `src/types/`, `src/features/` are introduced in Phase 1.
