# Frontend Phase 1: Shell + Overview Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the single-page dashboard dump with an app shell (project sidebar, breadcrumbs, theme toggle) and a focused Overview page, per `docs/superpowers/specs/2026-06-12-frontend-uiux-design.md` Phase 1.

**Architecture:** Pure frontend phase — everything renders from the existing `GET /api/v1/state` payload hydrated by the `observability:dashboard` channel (no backend changes). The old `DashboardPage` is dissolved: metrics and active runs move to the new `OverviewPage`, runtime/rate-limits move to a new `RuntimePage`, blocked/retry tables are superseded by a "Needs attention" list, and the 1 s clock re-render is isolated into a leaf `<ElapsedTime>` component.

**Tech Stack:** React 19, React Router v7, TanStack Query v5, next-themes (already installed), shadcn/base-nova + Tailwind v4, Vitest + React Testing Library, Playwright e2e.

**Working directory:** all `npm` commands run in `elixir/assets/`. `make e2e` runs in `elixir/`. Read `elixir/assets/CLAUDE.md` before starting — it documents the conventions this plan follows (no `fetch` in components, shadcn `src/components/ui/*` are generated, `@/*` → `src/*`).

**Transitional decisions (intentional, do not "fix"):**

- Sidebar project rows link to `/projects/:id/edit` (the only per-project page today). Phase 2 repoints them to `/projects/:slug`.
- Work-runs and artifacts tables disappear from the UI until Phases 2/4 deliver their real homes (project history, Evidence tab). The e2e artifact assertions are removed in Task 11 and return in Phase 4.
- `features/dashboard/` keeps `useDashboard.ts` and `ConnectionStatus.tsx` — they are shared infrastructure, not page code.

## File Structure

| File | Action | Responsibility |
| --- | --- | --- |
| `src/test/setup.ts` | Modify | Add `matchMedia` stub for next-themes under jsdom |
| `src/components/theme/ThemeProvider.tsx` | Create | next-themes wrapper: class strategy, light default |
| `src/components/theme/ThemeToggle.tsx` | Create | Light/dark toggle button |
| `src/components/ElapsedTime.tsx` | Create | Self-ticking elapsed-duration leaf (kills page-wide `useNow`) |
| `src/lib/health.ts` | Create | Pure helpers: `projectHealth`, `needsAttention` |
| `src/components/layout/Breadcrumbs.tsx` | Create | Path → crumb trail (`crumbsFor` pure + component) |
| `src/components/layout/Sidebar.tsx` | Create | Nav, project list with health dots, connection + theme footer |
| `src/components/layout/AppShell.tsx` | Rewrite | Sidebar + header(breadcrumbs) + scrollable main |
| `src/features/overview/components/MetricCards.tsx` | Move | From `features/dashboard/components/` (with its test) |
| `src/features/overview/components/NeedsAttention.tsx` | Create | Blocked / failing-retry / sandbox-warning list |
| `src/features/overview/components/ActiveRuns.tsx` | Create | Compact cross-project running table |
| `src/features/overview/components/ProjectHealthGrid.tsx` | Create | Card per project with health + counts |
| `src/features/overview/components/RecentActivity.tsx` | Create | Last 10 `durable.work_events` |
| `src/features/overview/OverviewPage.tsx` | Create | Assembles the above |
| `src/features/runtime/RuntimePage.tsx` | Create | Sandbox + rate limits page |
| `src/features/runtime/components/{RuntimeCard,RateLimits}.tsx` | Move | From `features/dashboard/components/` |
| `src/routes/NotFoundPage.tsx` | Rewrite | Designed 404 |
| `src/App.tsx` | Modify | `/` → Overview, add `/runtime` |
| `src/providers/AppProviders.tsx` | Modify | Wrap in `ThemeProvider` |
| `src/routes/DashboardPage.tsx` + dead tables | Delete | Superseded (Task 8) |
| `e2e/react-spa.spec.ts`, `assets/CLAUDE.md` | Modify | New assertions, routing note (Task 11) |

---

### Task 1: Theme infrastructure (provider + toggle)

**Files:**
- Modify: `src/test/setup.ts`
- Create: `src/components/theme/ThemeProvider.tsx`
- Create: `src/components/theme/ThemeToggle.tsx`
- Test: `src/components/theme/ThemeToggle.test.tsx`
- Modify: `src/providers/AppProviders.tsx`

- [ ] **Step 1: Stub `matchMedia` in the test setup** (next-themes reads it; jsdom lacks it)

Replace the content of `src/test/setup.ts` with:

```ts
import "@testing-library/jest-dom/vitest";

// next-themes reads window.matchMedia; jsdom doesn't implement it.
if (typeof window !== "undefined" && !window.matchMedia) {
  Object.defineProperty(window, "matchMedia", {
    writable: true,
    value: (query: string): MediaQueryList =>
      ({
        matches: false,
        media: query,
        onchange: null,
        addListener: () => {},
        removeListener: () => {},
        addEventListener: () => {},
        removeEventListener: () => {},
        dispatchEvent: () => false,
      }) as unknown as MediaQueryList,
  });
}
```

- [ ] **Step 2: Write the failing test**

Create `src/components/theme/ThemeToggle.test.tsx`:

```tsx
import { render, screen } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { describe, it, expect, afterEach } from "vitest";
import { ThemeProvider } from "@/components/theme/ThemeProvider";
import { ThemeToggle } from "@/components/theme/ThemeToggle";

afterEach(() => {
  localStorage.clear();
  document.documentElement.classList.remove("dark", "light");
});

describe("ThemeToggle", () => {
  it("toggles the dark class on <html>", async () => {
    const user = userEvent.setup();
    render(
      <ThemeProvider>
        <ThemeToggle />
      </ThemeProvider>,
    );

    const button = await screen.findByRole("button", { name: /switch to dark mode/i });
    await user.click(button);
    expect(document.documentElement.classList.contains("dark")).toBe(true);

    await user.click(screen.getByRole("button", { name: /switch to light mode/i }));
    expect(document.documentElement.classList.contains("dark")).toBe(false);
  });
});
```

- [ ] **Step 3: Run the test to verify it fails**

Run: `npm run test -- --run src/components/theme/ThemeToggle.test.tsx`
Expected: FAIL — cannot resolve `@/components/theme/ThemeProvider`.

- [ ] **Step 4: Implement provider and toggle**

Create `src/components/theme/ThemeProvider.tsx`:

```tsx
import { ThemeProvider as NextThemesProvider } from "next-themes";
import type { ReactNode } from "react";

// Studio direction: light by default, dark as an explicit toggle (class on <html>).
export function ThemeProvider({ children }: { children: ReactNode }) {
  return (
    <NextThemesProvider
      attribute="class"
      defaultTheme="light"
      enableSystem={false}
      disableTransitionOnChange
    >
      {children}
    </NextThemesProvider>
  );
}
```

Create `src/components/theme/ThemeToggle.tsx`:

```tsx
import { Moon, Sun } from "lucide-react";
import { useTheme } from "next-themes";
import { Button } from "@/components/ui/button";

export function ThemeToggle() {
  const { resolvedTheme, setTheme } = useTheme();
  const isDark = resolvedTheme === "dark";

  return (
    <Button
      variant="ghost"
      size="icon"
      aria-label={isDark ? "Switch to light mode" : "Switch to dark mode"}
      onClick={() => setTheme(isDark ? "light" : "dark")}
    >
      {isDark ? <Sun className="size-4" /> : <Moon className="size-4" />}
    </Button>
  );
}
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `npm run test -- --run src/components/theme/ThemeToggle.test.tsx`
Expected: PASS (2 assertions through one test).

- [ ] **Step 6: Wire the provider into the app**

In `src/providers/AppProviders.tsx`, import and wrap (outermost inside the ErrorBoundary):

```tsx
import { QueryClientProvider } from "@tanstack/react-query";
import type { ReactNode } from "react";
import { queryClient } from "@/lib/queryClient";
import { DashboardConnectionProvider, useDashboardConnection } from "@/lib/dashboardConnection";
import { useDashboardChannel } from "@/lib/socket";
import { ErrorBoundary } from "@/components/ErrorBoundary";
import { ThemeProvider } from "@/components/theme/ThemeProvider";
import { Toaster } from "@/components/ui/sonner";

function ChannelBridge({ children }: { children: ReactNode }) {
  const { setStatus } = useDashboardConnection();
  useDashboardChannel(queryClient, setStatus);
  return <>{children}</>;
}

export function AppProviders({ children }: { children: ReactNode }) {
  return (
    <ErrorBoundary>
      <ThemeProvider>
        <QueryClientProvider client={queryClient}>
          <DashboardConnectionProvider>
            <ChannelBridge>{children}</ChannelBridge>
          </DashboardConnectionProvider>
          <Toaster />
        </QueryClientProvider>
      </ThemeProvider>
    </ErrorBoundary>
  );
}
```

- [ ] **Step 7: Run the whole suite and typecheck**

Run: `npm run test -- --run && npm run typecheck`
Expected: PASS, no type errors.

- [ ] **Step 8: Commit**

```bash
git add src/test/setup.ts src/components/theme src/providers/AppProviders.tsx
git commit -m "feat(frontend): add theme provider and light/dark toggle"
```

---

### Task 2: `<ElapsedTime>` leaf component

**Files:**
- Create: `src/components/ElapsedTime.tsx`
- Test: `src/components/ElapsedTime.test.tsx`

- [ ] **Step 1: Write the failing test**

Create `src/components/ElapsedTime.test.tsx`:

```tsx
import { render, screen } from "@testing-library/react";
import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import { ElapsedTime } from "@/components/ElapsedTime";

beforeEach(() => {
  vi.useFakeTimers();
  vi.setSystemTime(new Date("2026-06-12T12:01:05Z"));
});
afterEach(() => vi.useRealTimers());

describe("ElapsedTime", () => {
  it("renders the elapsed duration since the timestamp", () => {
    render(<ElapsedTime since="2026-06-12T12:00:00Z" />);
    expect(screen.getByText("1m 5s")).toBeInTheDocument();
  });

  it("renders a dash when there is no timestamp", () => {
    render(<ElapsedTime since={null} />);
    expect(screen.getByText("—")).toBeInTheDocument();
  });
});
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `npm run test -- --run src/components/ElapsedTime.test.tsx`
Expected: FAIL — cannot resolve `@/components/ElapsedTime`.

- [ ] **Step 3: Implement**

Create `src/components/ElapsedTime.tsx`:

```tsx
import { useNow } from "@/lib/useNow";
import { elapsedSeconds, formatDuration } from "@/lib/format";

// The 1s clock lives here, in a leaf, so ticking re-renders only this span —
// not the page that renders it (the old DashboardPage re-rendered wholesale).
export function ElapsedTime({ since }: { since: string | null }) {
  const nowMs = useNow();
  const seconds = elapsedSeconds(since, nowMs);
  if (seconds == null) return <span>—</span>;
  return <span className="font-mono text-sm tabular-nums">{formatDuration(seconds)}</span>;
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `npm run test -- --run src/components/ElapsedTime.test.tsx`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/components/ElapsedTime.tsx src/components/ElapsedTime.test.tsx
git commit -m "feat(frontend): add self-ticking ElapsedTime leaf component"
```

---

### Task 3: Health helpers (`projectHealth`, `needsAttention`)

**Files:**
- Create: `src/lib/health.ts`
- Test: `src/lib/health.test.ts`

- [ ] **Step 1: Write the failing test**

Create `src/lib/health.test.ts`:

```ts
import { describe, it, expect } from "vitest";
import { projectHealth, needsAttention } from "@/lib/health";

describe("projectHealth", () => {
  it("is blocked when anything is blocked", () => {
    expect(projectHealth({ running: 3, retrying: 2, blocked: 1 })).toBe("blocked");
  });
  it("is retrying when retries pend and nothing is blocked", () => {
    expect(projectHealth({ running: 3, retrying: 2, blocked: 0 })).toBe("retrying");
  });
  it("is healthy when only running", () => {
    expect(projectHealth({ running: 3, retrying: 0, blocked: 0 })).toBe("healthy");
  });
  it("is idle when nothing is active", () => {
    expect(projectHealth({ running: 0, retrying: 0, blocked: 0 })).toBe("idle");
  });
});

describe("needsAttention", () => {
  it("collects blocked runs, failing retries, and sandbox warnings", () => {
    const items = needsAttention({
      generated_at: "2026-06-12T00:00:00Z",
      blocked: [
        {
          issue_id: "b1",
          issue_identifier: "HAR-42",
          state: "In Progress",
          error: "sandbox denied",
          worker_host: null,
          workspace_path: null,
          session_id: null,
          blocked_at: "2026-06-12T00:00:00Z",
          last_event: null,
          last_message: null,
          last_event_at: null,
          project: { id: "p1", name: "Alpha", slug: "alpha" },
        },
      ],
      retrying: [
        {
          issue_id: "r1",
          issue_identifier: "HAR-38",
          attempt: 3,
          due_at: null,
          error: "agent timeout",
          worker_host: null,
          workspace_path: null,
          project: null,
        },
        {
          issue_id: "r2",
          issue_identifier: "HAR-39",
          attempt: 1,
          due_at: null,
          error: null,
          worker_host: null,
          workspace_path: null,
          project: null,
        },
      ],
      runtime: {
        sandbox: {
          posture: null,
          bubblewrap_available: null,
          apparmor_restrict_unprivileged_userns: null,
          thread_sandbox: null,
          turn_sandbox_type: null,
          warnings: ["bubblewrap unavailable"],
        },
      },
    });

    expect(items.map((i) => i.kind)).toEqual(["blocked", "retry_error", "sandbox_warning"]);
    expect(items[0].identifier).toBe("HAR-42");
    expect(items[0].projectSlug).toBe("alpha");
    expect(items[1].message).toContain("agent timeout");
    // HAR-39 has no error -> a pending retry is normal operation, not attention-worthy.
    expect(items.find((i) => i.identifier === "HAR-39")).toBeUndefined();
  });

  it("returns an empty list when everything is clear", () => {
    expect(needsAttention({ generated_at: "2026-06-12T00:00:00Z" })).toEqual([]);
  });
});
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `npm run test -- --run src/lib/health.test.ts`
Expected: FAIL — cannot resolve `@/lib/health`.

- [ ] **Step 3: Implement**

Create `src/lib/health.ts`:

```ts
import type { ProjectCounts, StatePayload } from "@/types/contract";

export type ProjectHealth = "healthy" | "retrying" | "blocked" | "idle";

export function projectHealth(counts: ProjectCounts): ProjectHealth {
  if (counts.blocked > 0) return "blocked";
  if (counts.retrying > 0) return "retrying";
  if (counts.running > 0) return "healthy";
  return "idle";
}

export interface AttentionItem {
  key: string;
  kind: "blocked" | "retry_error" | "sandbox_warning";
  identifier: string | null;
  projectSlug: string | null;
  message: string;
  since: string | null;
}

// Spec: Overview "Needs attention" = blocked runs, retries carrying errors,
// sandbox warnings. Order: blocked first (most urgent), then retries, then runtime.
export function needsAttention(state: StatePayload): AttentionItem[] {
  const items: AttentionItem[] = [];

  for (const b of state.blocked ?? []) {
    items.push({
      key: `blocked-${b.issue_id}`,
      kind: "blocked",
      identifier: b.issue_identifier,
      projectSlug: b.project?.slug ?? null,
      message: b.error ?? b.last_message ?? "Blocked",
      since: b.blocked_at,
    });
  }

  for (const r of state.retrying ?? []) {
    if (!r.error) continue;
    items.push({
      key: `retry-${r.issue_id}`,
      kind: "retry_error",
      identifier: r.issue_identifier,
      projectSlug: r.project?.slug ?? null,
      message: `Retry #${r.attempt}: ${r.error}`,
      since: r.due_at,
    });
  }

  for (const warning of state.runtime?.sandbox?.warnings ?? []) {
    items.push({
      key: `sandbox-${warning}`,
      kind: "sandbox_warning",
      identifier: null,
      projectSlug: null,
      message: warning,
      since: null,
    });
  }

  return items;
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `npm run test -- --run src/lib/health.test.ts`
Expected: PASS (6 tests).

- [ ] **Step 5: Commit**

```bash
git add src/lib/health.ts src/lib/health.test.ts
git commit -m "feat(frontend): add project health and needs-attention helpers"
```

---

### Task 4: Breadcrumbs

**Files:**
- Create: `src/components/layout/Breadcrumbs.tsx`
- Test: `src/components/layout/Breadcrumbs.test.tsx`

- [ ] **Step 1: Write the failing test**

Create `src/components/layout/Breadcrumbs.test.tsx`:

```tsx
import { render, screen } from "@testing-library/react";
import { MemoryRouter } from "react-router-dom";
import { describe, it, expect } from "vitest";
import { Breadcrumbs, crumbsFor } from "@/components/layout/Breadcrumbs";

describe("crumbsFor", () => {
  it("maps known paths to crumb trails", () => {
    expect(crumbsFor("/")).toEqual([{ label: "Overview", to: "/" }]);
    expect(crumbsFor("/runtime").map((c) => c.label)).toEqual(["Overview", "Runtime"]);
    expect(crumbsFor("/projects").map((c) => c.label)).toEqual(["Overview", "Projects"]);
    expect(crumbsFor("/projects/new").map((c) => c.label)).toEqual([
      "Overview",
      "Projects",
      "New",
    ]);
    expect(crumbsFor("/projects/p1/edit").map((c) => c.label)).toEqual([
      "Overview",
      "Projects",
      "Edit",
    ]);
  });
});

describe("Breadcrumbs", () => {
  it("renders the trail with the current page unlinked", () => {
    render(
      <MemoryRouter initialEntries={["/projects/new"]}>
        <Breadcrumbs />
      </MemoryRouter>,
    );
    const nav = screen.getByRole("navigation", { name: "Breadcrumb" });
    expect(nav).toBeInTheDocument();
    expect(screen.getByRole("link", { name: "Projects" })).toHaveAttribute("href", "/projects");
    // current crumb is text, not a link
    expect(screen.queryByRole("link", { name: "New" })).not.toBeInTheDocument();
    expect(screen.getByText("New")).toHaveAttribute("aria-current", "page");
  });
});
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `npm run test -- --run src/components/layout/Breadcrumbs.test.tsx`
Expected: FAIL — cannot resolve `@/components/layout/Breadcrumbs`.

- [ ] **Step 3: Implement**

Create `src/components/layout/Breadcrumbs.tsx`:

```tsx
import { Fragment } from "react";
import { Link, useLocation } from "react-router-dom";

export interface Crumb {
  label: string;
  to: string;
}

// Static path→label mapping. Phase 2+ extends this with project/run names
// once routes carry slugs worth displaying.
export function crumbsFor(pathname: string): Crumb[] {
  const crumbs: Crumb[] = [{ label: "Overview", to: "/" }];
  if (pathname === "/") return crumbs;

  const [first, second, third] = pathname.split("/").filter(Boolean);
  if (first === "runtime") return [...crumbs, { label: "Runtime", to: "/runtime" }];
  if (first === "projects") {
    crumbs.push({ label: "Projects", to: "/projects" });
    if (second === "new") crumbs.push({ label: "New", to: "/projects/new" });
    else if (second && third === "edit") crumbs.push({ label: "Edit", to: pathname });
    return crumbs;
  }
  return [...crumbs, { label: "Not found", to: pathname }];
}

export function Breadcrumbs() {
  const { pathname } = useLocation();
  const crumbs = crumbsFor(pathname);

  return (
    <nav aria-label="Breadcrumb" className="flex items-center gap-1.5 text-sm text-muted-foreground">
      {crumbs.map((crumb, i) => {
        const last = i === crumbs.length - 1;
        return (
          <Fragment key={crumb.to}>
            {i > 0 ? <span aria-hidden>/</span> : null}
            {last ? (
              <span aria-current="page" className="text-foreground">
                {crumb.label}
              </span>
            ) : (
              <Link to={crumb.to} className="hover:text-foreground">
                {crumb.label}
              </Link>
            )}
          </Fragment>
        );
      })}
    </nav>
  );
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `npm run test -- --run src/components/layout/Breadcrumbs.test.tsx`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/components/layout/Breadcrumbs.tsx src/components/layout/Breadcrumbs.test.tsx
git commit -m "feat(frontend): add breadcrumbs component"
```

---

### Task 5: Sidebar

**Files:**
- Create: `src/components/layout/Sidebar.tsx`
- Test: `src/components/layout/Sidebar.test.tsx`

- [ ] **Step 1: Write the failing test**

Create `src/components/layout/Sidebar.test.tsx`:

```tsx
import { render, screen, waitFor } from "@testing-library/react";
import { MemoryRouter } from "react-router-dom";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { describe, it, expect, vi, afterEach } from "vitest";
import { Sidebar } from "@/components/layout/Sidebar";
import { DashboardConnectionProvider } from "@/lib/dashboardConnection";

afterEach(() => vi.restoreAllMocks());

function renderSidebar(statePayload: object) {
  vi.stubGlobal(
    "fetch",
    vi.fn(
      async () =>
        new Response(JSON.stringify(statePayload), {
          status: 200,
          headers: { "content-type": "application/json" },
        }),
    ),
  );
  const qc = new QueryClient({ defaultOptions: { queries: { retry: false } } });
  return render(
    <QueryClientProvider client={qc}>
      <DashboardConnectionProvider>
        <MemoryRouter>
          <Sidebar />
        </MemoryRouter>
      </DashboardConnectionProvider>
    </QueryClientProvider>,
  );
}

describe("Sidebar", () => {
  it("lists projects with active-session counts and links", async () => {
    renderSidebar({
      generated_at: "2026-06-12T00:00:00Z",
      counts: { running: 1, retrying: 0, blocked: 1 },
      running: [],
      retrying: [],
      blocked: [],
      projects: [
        { id: "p1", slug: "alpha", name: "Alpha", counts: { running: 1, retrying: 0, blocked: 0 } },
        { id: "p2", slug: "beta", name: "Beta", counts: { running: 0, retrying: 0, blocked: 1 } },
      ],
    });

    await waitFor(() => expect(screen.getByText("alpha")).toBeInTheDocument());
    expect(screen.getByText("beta")).toBeInTheDocument();
    // transitional Phase 1 target: the project's config page
    expect(screen.getByRole("link", { name: /alpha/ })).toHaveAttribute(
      "href",
      "/projects/p1/edit",
    );
    expect(screen.getByRole("link", { name: "Overview" })).toBeInTheDocument();
    expect(screen.getByRole("link", { name: "Runtime" })).toBeInTheDocument();
    expect(screen.getByRole("link", { name: "Create project" })).toHaveAttribute(
      "href",
      "/projects/new",
    );
  });

  it("shows an empty state without projects", async () => {
    renderSidebar({ generated_at: "2026-06-12T00:00:00Z" });
    await waitFor(() => expect(screen.getByText(/no projects yet/i)).toBeInTheDocument());
  });
});
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `npm run test -- --run src/components/layout/Sidebar.test.tsx`
Expected: FAIL — cannot resolve `@/components/layout/Sidebar`.

- [ ] **Step 3: Implement**

Create `src/components/layout/Sidebar.tsx`:

```tsx
import { Activity, LayoutDashboard, Plus } from "lucide-react";
import { Link, NavLink } from "react-router-dom";
import { ThemeToggle } from "@/components/theme/ThemeToggle";
import { ConnectionStatus } from "@/features/dashboard/components/ConnectionStatus";
import { useDashboard } from "@/features/dashboard/useDashboard";
import { projectHealth, type ProjectHealth } from "@/lib/health";
import { cn } from "@/lib/utils";

const healthDot: Record<ProjectHealth, string> = {
  healthy: "bg-emerald-500",
  retrying: "bg-amber-500",
  blocked: "bg-red-500",
  idle: "bg-muted-foreground/40",
};

function navLinkClass({ isActive }: { isActive: boolean }) {
  return cn(
    "flex items-center gap-2 rounded-md px-2 py-1.5 text-sm",
    isActive
      ? "bg-sidebar-accent font-medium text-sidebar-accent-foreground"
      : "hover:bg-sidebar-accent/50",
  );
}

export function Sidebar() {
  const { data } = useDashboard();
  const projects = data?.projects ?? [];

  return (
    <aside className="flex w-60 shrink-0 flex-col border-r bg-sidebar text-sidebar-foreground">
      <div className="px-4 py-4 text-base font-semibold">
        <Link to="/">Harmony</Link>
      </div>

      <nav aria-label="Main" className="flex-1 space-y-6 overflow-y-auto px-2">
        <div className="space-y-1">
          <NavLink to="/" end className={navLinkClass}>
            <LayoutDashboard className="size-4" /> Overview
          </NavLink>
          <NavLink to="/runtime" className={navLinkClass}>
            <Activity className="size-4" /> Runtime
          </NavLink>
        </div>

        <div>
          <div className="flex items-center justify-between px-2 pb-1">
            <NavLink
              to="/projects"
              end
              className="text-xs font-medium uppercase tracking-wide text-muted-foreground hover:text-foreground"
            >
              Projects
            </NavLink>
            <Link
              to="/projects/new"
              aria-label="Create project"
              className="text-muted-foreground hover:text-foreground"
            >
              <Plus className="size-4" />
            </Link>
          </div>
          <ul className="space-y-1">
            {projects.map((p) => {
              const health = projectHealth(p.counts);
              const active = p.counts.running + p.counts.retrying + p.counts.blocked;
              return (
                <li key={p.id ?? p.slug ?? p.name ?? "unknown"}>
                  {/* Phase 1 transitional target; Phase 2 repoints to /projects/:slug */}
                  <Link
                    to={p.id ? `/projects/${p.id}/edit` : "/projects"}
                    className="flex items-center gap-2 rounded-md px-2 py-1.5 text-sm hover:bg-sidebar-accent/50"
                  >
                    <span aria-hidden className={cn("size-2 rounded-full", healthDot[health])} />
                    <span className="truncate">{p.slug ?? p.name ?? "unnamed"}</span>
                    {active > 0 ? (
                      <span className="ml-auto font-mono text-xs text-muted-foreground">
                        {active}
                      </span>
                    ) : null}
                  </Link>
                </li>
              );
            })}
            {projects.length === 0 ? (
              <li className="px-2 py-1.5 text-sm text-muted-foreground">No projects yet</li>
            ) : null}
          </ul>
        </div>
      </nav>

      <div className="flex items-center justify-between border-t px-4 py-3">
        <ConnectionStatus />
        <ThemeToggle />
      </div>
    </aside>
  );
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `npm run test -- --run src/components/layout/Sidebar.test.tsx`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/components/layout/Sidebar.tsx src/components/layout/Sidebar.test.tsx
git commit -m "feat(frontend): add project sidebar with health dots"
```

---

### Task 6: AppShell rewrite

**Files:**
- Modify: `src/components/layout/AppShell.tsx`
- Modify: `src/App.test.tsx`

- [ ] **Step 1: Update `App.test.tsx` to the new shell expectations**

The shell will render two `<nav>` elements (sidebar "Main" + "Breadcrumb"), and the
sidebar's `ConnectionStatus` needs `DashboardConnectionProvider`. Replace the
`renderAt` helper and the first test in `src/App.test.tsx`:

```tsx
import { render, screen } from "@testing-library/react";
import { MemoryRouter } from "react-router-dom";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import { AppRoutes } from "@/App";
import { DashboardConnectionProvider } from "@/lib/dashboardConnection";

beforeEach(() => {
  vi.stubGlobal(
    "fetch",
    vi.fn(
      async () =>
        new Response(
          JSON.stringify({
            generated_at: "2026-06-02T00:00:00Z",
            counts: { running: 0, retrying: 0, blocked: 0 },
            running: [],
            retrying: [],
            blocked: [],
          }),
          { status: 200, headers: { "content-type": "application/json" } },
        ),
    ),
  );
});
afterEach(() => vi.restoreAllMocks());

function renderAt(path: string) {
  const qc = new QueryClient({ defaultOptions: { queries: { retry: false } } });
  return render(
    <QueryClientProvider client={qc}>
      <DashboardConnectionProvider>
        <MemoryRouter initialEntries={[path]}>
          <AppRoutes />
        </MemoryRouter>
      </DashboardConnectionProvider>
    </QueryClientProvider>,
  );
}

describe("AppRoutes", () => {
  it("shows the sidebar nav and the dashboard at /", () => {
    renderAt("/");
    expect(screen.getByRole("navigation", { name: "Main" })).toBeInTheDocument();
    expect(screen.getByRole("navigation", { name: "Breadcrumb" })).toBeInTheDocument();
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

(The `/dashboard/i` heading assertion is intentionally kept — `/` still renders the
old `DashboardPage` until Task 8 swaps in the Overview.)

- [ ] **Step 2: Run the test to verify it fails**

Run: `npm run test -- --run src/App.test.tsx`
Expected: FAIL — no element with role `navigation` and name `Main` (old shell has an unnamed nav).

- [ ] **Step 3: Rewrite the shell**

Replace `src/components/layout/AppShell.tsx` with:

```tsx
import { Outlet } from "react-router-dom";
import { Breadcrumbs } from "@/components/layout/Breadcrumbs";
import { Sidebar } from "@/components/layout/Sidebar";

export function AppShell() {
  return (
    <div className="flex h-screen bg-background text-foreground">
      <Sidebar />
      <div className="flex min-w-0 flex-1 flex-col">
        <header className="flex h-12 shrink-0 items-center border-b px-6">
          <Breadcrumbs />
        </header>
        <main className="flex-1 overflow-y-auto p-6">
          <Outlet />
        </main>
      </div>
    </div>
  );
}
```

- [ ] **Step 4: Run the suite to verify it passes**

Run: `npm run test -- --run`
Expected: PASS — including the untouched `DashboardPage.test.tsx` (it renders the page
directly, not through the shell).

- [ ] **Step 5: Commit**

```bash
git add src/components/layout/AppShell.tsx src/App.test.tsx
git commit -m "feat(frontend): replace top nav with sidebar app shell"
```

---

### Task 7: Overview section components

**Files:**
- Move: `src/features/dashboard/components/MetricCards.tsx` → `src/features/overview/components/MetricCards.tsx` (and its `.test.tsx`)
- Modify: `src/routes/DashboardPage.tsx` (one import line)
- Create: `src/features/overview/components/NeedsAttention.tsx`
- Create: `src/features/overview/components/ActiveRuns.tsx`
- Create: `src/features/overview/components/ProjectHealthGrid.tsx`
- Create: `src/features/overview/components/RecentActivity.tsx`
- Test: `src/features/overview/components/NeedsAttention.test.tsx`
- Test: `src/features/overview/components/ProjectHealthGrid.test.tsx`
- Test: `src/features/overview/components/ActiveRuns.test.tsx`
- Test: `src/features/overview/components/RecentActivity.test.tsx`

- [ ] **Step 1: Move MetricCards into the overview feature**

```bash
mkdir -p src/features/overview/components
git mv src/features/dashboard/components/MetricCards.tsx src/features/overview/components/MetricCards.tsx
git mv src/features/dashboard/components/MetricCards.test.tsx src/features/overview/components/MetricCards.test.tsx
```

Update the import inside `src/features/overview/components/MetricCards.test.tsx`:

```tsx
import { MetricCards } from "@/features/overview/components/MetricCards";
```

Update the import inside `src/routes/DashboardPage.tsx` (page dies in Task 8; keep it green until then):

```tsx
import { MetricCards } from "@/features/overview/components/MetricCards";
```

Run: `npm run test -- --run && npm run typecheck`
Expected: PASS.

- [ ] **Step 2: Write the failing tests for the four new components**

Create `src/features/overview/components/NeedsAttention.test.tsx`:

```tsx
import { render, screen } from "@testing-library/react";
import { describe, it, expect } from "vitest";
import { NeedsAttention } from "@/features/overview/components/NeedsAttention";

describe("NeedsAttention", () => {
  it("renders blocked and retry items with badges", () => {
    render(
      <NeedsAttention
        state={{
          generated_at: "2026-06-12T00:00:00Z",
          blocked: [
            {
              issue_id: "b1",
              issue_identifier: "HAR-42",
              state: "In Progress",
              error: "sandbox denied",
              worker_host: null,
              workspace_path: null,
              session_id: null,
              blocked_at: null,
              last_event: null,
              last_message: null,
              last_event_at: null,
              project: { id: "p1", name: "Alpha", slug: "alpha" },
            },
          ],
          retrying: [
            {
              issue_id: "r1",
              issue_identifier: "HAR-38",
              attempt: 3,
              due_at: null,
              error: "agent timeout",
              worker_host: null,
              workspace_path: null,
              project: null,
            },
          ],
        }}
      />,
    );

    expect(screen.getByText("HAR-42")).toBeInTheDocument();
    expect(screen.getByText("Blocked")).toBeInTheDocument();
    expect(screen.getByText("sandbox denied")).toBeInTheDocument();
    expect(screen.getByText("Retry failing")).toBeInTheDocument();
    expect(screen.getByText(/agent timeout/)).toBeInTheDocument();
  });

  it("renders the all-clear message when nothing needs attention", () => {
    render(<NeedsAttention state={{ generated_at: "2026-06-12T00:00:00Z" }} />);
    expect(screen.getByText(/all clear/i)).toBeInTheDocument();
  });
});
```

Create `src/features/overview/components/ProjectHealthGrid.test.tsx`:

```tsx
import { render, screen } from "@testing-library/react";
import { MemoryRouter } from "react-router-dom";
import { describe, it, expect } from "vitest";
import { ProjectHealthGrid } from "@/features/overview/components/ProjectHealthGrid";

describe("ProjectHealthGrid", () => {
  it("renders a card per project with counts", () => {
    render(
      <MemoryRouter>
        <ProjectHealthGrid
          projects={[
            {
              id: "p1",
              slug: "alpha",
              name: "Alpha",
              counts: { running: 2, retrying: 1, blocked: 0 },
            },
          ]}
        />
      </MemoryRouter>,
    );
    expect(screen.getByText("alpha")).toBeInTheDocument();
    expect(screen.getByText("2 running")).toBeInTheDocument();
    expect(screen.getByText("1 retrying")).toBeInTheDocument();
    expect(screen.getByText("0 blocked")).toBeInTheDocument();
  });

  it("offers creating the first project when the list is empty", () => {
    render(
      <MemoryRouter>
        <ProjectHealthGrid projects={[]} />
      </MemoryRouter>,
    );
    expect(screen.getByRole("link", { name: /create the first one/i })).toHaveAttribute(
      "href",
      "/projects/new",
    );
  });
});
```

Create `src/features/overview/components/ActiveRuns.test.tsx`:

```tsx
import { render, screen } from "@testing-library/react";
import { describe, it, expect } from "vitest";
import { ActiveRuns } from "@/features/overview/components/ActiveRuns";

describe("ActiveRuns", () => {
  it("renders a row per running session", () => {
    render(
      <ActiveRuns
        rows={[
          {
            issue_id: "i1",
            issue_identifier: "HAR-44",
            state: "In Progress",
            worker_host: null,
            workspace_path: null,
            session_id: "s1",
            turn_count: 7,
            last_event: "turn_completed",
            last_message: null,
            started_at: "2026-06-12T00:00:00Z",
            last_event_at: null,
            tokens: { input_tokens: 1200, output_tokens: 800, total_tokens: 2000 },
            project: { id: "p1", name: "Alpha", slug: "alpha" },
          },
        ]}
      />,
    );
    expect(screen.getByText("HAR-44")).toBeInTheDocument();
    expect(screen.getByText("alpha")).toBeInTheDocument();
    expect(screen.getByText("7")).toBeInTheDocument();
    expect(screen.getByText("2,000")).toBeInTheDocument();
    expect(screen.getByText("turn_completed")).toBeInTheDocument();
  });

  it("renders an empty message without rows", () => {
    render(<ActiveRuns rows={[]} />);
    expect(screen.getByText(/no runs in progress/i)).toBeInTheDocument();
  });
});
```

Create `src/features/overview/components/RecentActivity.test.tsx`:

```tsx
import { render, screen } from "@testing-library/react";
import { describe, it, expect } from "vitest";
import { RecentActivity } from "@/features/overview/components/RecentActivity";

function event(id: string, type: string, insertedAt: string) {
  return { id, project_id: null, work_run_id: null, type, payload: null, inserted_at: insertedAt };
}

describe("RecentActivity", () => {
  it("renders newest events first, capped at 10", () => {
    const events = Array.from({ length: 12 }, (_, i) =>
      event(`e${i}`, `event_${i}`, `2026-06-12T00:${String(i).padStart(2, "0")}:00Z`),
    );
    render(<RecentActivity events={events} />);

    const items = screen.getAllByRole("listitem");
    expect(items).toHaveLength(10);
    // newest (event_11) first; oldest two (event_0, event_1) dropped
    expect(items[0]).toHaveTextContent("event_11");
    expect(screen.queryByText("event_0")).not.toBeInTheDocument();
  });

  it("renders nothing without events", () => {
    const { container } = render(<RecentActivity events={[]} />);
    expect(container).toBeEmptyDOMElement();
  });
});
```

- [ ] **Step 3: Run the tests to verify they fail**

Run: `npm run test -- --run src/features/overview`
Expected: FAIL — the four new modules don't resolve (MetricCards test passes).

- [ ] **Step 4: Implement the four components**

Create `src/features/overview/components/NeedsAttention.tsx`:

```tsx
import { ElapsedTime } from "@/components/ElapsedTime";
import { Badge } from "@/components/ui/badge";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { needsAttention, type AttentionItem } from "@/lib/health";
import type { StatePayload } from "@/types/contract";

const kindLabels: Record<AttentionItem["kind"], string> = {
  blocked: "Blocked",
  retry_error: "Retry failing",
  sandbox_warning: "Sandbox",
};

export function NeedsAttention({ state }: { state: StatePayload }) {
  const items = needsAttention(state);

  return (
    <Card>
      <CardHeader>
        <CardTitle className="text-base">Needs attention</CardTitle>
      </CardHeader>
      <CardContent>
        {items.length === 0 ? (
          <p className="text-sm text-muted-foreground">All clear — nothing needs attention.</p>
        ) : (
          <ul className="divide-y">
            {items.map((item) => (
              <li key={item.key} className="flex items-center gap-3 py-2 text-sm">
                <Badge variant={item.kind === "sandbox_warning" ? "outline" : "destructive"}>
                  {kindLabels[item.kind]}
                </Badge>
                {item.identifier ? <span className="font-mono">{item.identifier}</span> : null}
                {item.projectSlug ? (
                  <span className="text-muted-foreground">{item.projectSlug}</span>
                ) : null}
                <span className="min-w-0 flex-1 truncate" title={item.message}>
                  {item.message}
                </span>
                {item.since ? <ElapsedTime since={item.since} /> : null}
              </li>
            ))}
          </ul>
        )}
      </CardContent>
    </Card>
  );
}
```

Create `src/features/overview/components/ActiveRuns.tsx`:

```tsx
import { ElapsedTime } from "@/components/ElapsedTime";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import {
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from "@/components/ui/table";
import type { RunningEntry } from "@/types/contract";

export function ActiveRuns({ rows }: { rows: RunningEntry[] }) {
  return (
    <Card>
      <CardHeader>
        <CardTitle className="text-base">Active runs</CardTitle>
      </CardHeader>
      <CardContent>
        {rows.length === 0 ? (
          <p className="text-sm text-muted-foreground">No runs in progress.</p>
        ) : (
          <Table>
            <TableHeader>
              <TableRow>
                <TableHead>Issue</TableHead>
                <TableHead>Project</TableHead>
                <TableHead>State</TableHead>
                <TableHead>Turns</TableHead>
                <TableHead>Tokens</TableHead>
                <TableHead>Elapsed</TableHead>
                <TableHead>Last event</TableHead>
              </TableRow>
            </TableHeader>
            <TableBody>
              {rows.map((row) => (
                <TableRow key={row.issue_id}>
                  <TableCell className="font-mono">{row.issue_identifier}</TableCell>
                  <TableCell>{row.project?.slug ?? "—"}</TableCell>
                  <TableCell>{row.state}</TableCell>
                  <TableCell className="font-mono">{row.turn_count}</TableCell>
                  <TableCell className="font-mono">
                    {row.tokens.total_tokens.toLocaleString("en-US")}
                  </TableCell>
                  <TableCell>
                    <ElapsedTime since={row.started_at} />
                  </TableCell>
                  <TableCell className="text-muted-foreground">{row.last_event ?? "—"}</TableCell>
                </TableRow>
              ))}
            </TableBody>
          </Table>
        )}
      </CardContent>
    </Card>
  );
}
```

Create `src/features/overview/components/ProjectHealthGrid.tsx`:

```tsx
import { Link } from "react-router-dom";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { projectHealth, type ProjectHealth } from "@/lib/health";
import { cn } from "@/lib/utils";
import type { ProjectCounts, ProjectRef } from "@/types/contract";

const healthStyles: Record<ProjectHealth, string> = {
  healthy: "bg-emerald-500",
  retrying: "bg-amber-500",
  blocked: "bg-red-500",
  idle: "bg-muted-foreground/40",
};

export function ProjectHealthGrid({
  projects,
}: {
  projects: Array<ProjectRef & { counts: ProjectCounts }>;
}) {
  if (projects.length === 0) {
    return (
      <p className="text-sm text-muted-foreground">
        No projects configured yet.{" "}
        <Link className="underline underline-offset-4 hover:text-foreground" to="/projects/new">
          Create the first one.
        </Link>
      </p>
    );
  }

  return (
    <div className="grid gap-4 sm:grid-cols-2 lg:grid-cols-3">
      {projects.map((p) => {
        const health = projectHealth(p.counts);
        return (
          <Card key={p.id ?? p.slug ?? p.name ?? "unknown"}>
            <CardHeader>
              <CardTitle className="flex items-center gap-2 text-base">
                <span aria-hidden className={cn("size-2.5 rounded-full", healthStyles[health])} />
                <span className="truncate">{p.slug ?? p.name ?? "unnamed"}</span>
              </CardTitle>
            </CardHeader>
            <CardContent className="flex gap-4 font-mono text-sm text-muted-foreground">
              <span>{p.counts.running} running</span>
              <span>{p.counts.retrying} retrying</span>
              <span>{p.counts.blocked} blocked</span>
            </CardContent>
          </Card>
        );
      })}
    </div>
  );
}
```

Create `src/features/overview/components/RecentActivity.tsx`:

```tsx
import { ElapsedTime } from "@/components/ElapsedTime";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import type { DurableWorkEvent } from "@/types/contract";

export function RecentActivity({ events }: { events: DurableWorkEvent[] }) {
  const recent = [...events]
    .sort((a, b) => (b.inserted_at ?? "").localeCompare(a.inserted_at ?? ""))
    .slice(0, 10);

  if (recent.length === 0) return null;

  return (
    <Card>
      <CardHeader>
        <CardTitle className="text-base">Recent activity</CardTitle>
      </CardHeader>
      <CardContent>
        <ul className="divide-y">
          {recent.map((e) => (
            <li key={e.id} className="flex items-center gap-3 py-2 text-sm">
              <span className="font-mono">{e.type}</span>
              <span className="min-w-0 flex-1" />
              {e.inserted_at ? (
                <span className="text-muted-foreground">
                  <ElapsedTime since={e.inserted_at} /> ago
                </span>
              ) : null}
            </li>
          ))}
        </ul>
      </CardContent>
    </Card>
  );
}
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `npm run test -- --run src/features/overview && npm run typecheck`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add src/features/overview src/features/dashboard src/routes/DashboardPage.tsx
git commit -m "feat(frontend): add overview section components"
```

---

### Task 8: OverviewPage + route swap + legacy cleanup

**Files:**
- Create: `src/features/overview/OverviewPage.tsx`
- Test: `src/features/overview/OverviewPage.test.tsx`
- Modify: `src/App.tsx`, `src/App.test.tsx`
- Delete: `src/routes/DashboardPage.tsx`, `src/routes/DashboardPage.test.tsx`, and superseded dashboard tables

- [ ] **Step 1: Write the failing page test**

Create `src/features/overview/OverviewPage.test.tsx`:

```tsx
import { render, screen, waitFor } from "@testing-library/react";
import { MemoryRouter } from "react-router-dom";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { describe, it, expect, vi, afterEach } from "vitest";
import { OverviewPage } from "@/features/overview/OverviewPage";

afterEach(() => vi.restoreAllMocks());

function renderPage(statePayload: object) {
  vi.stubGlobal(
    "fetch",
    vi.fn(
      async () =>
        new Response(JSON.stringify(statePayload), {
          status: 200,
          headers: { "content-type": "application/json" },
        }),
    ),
  );
  const qc = new QueryClient({ defaultOptions: { queries: { retry: false } } });
  return render(
    <QueryClientProvider client={qc}>
      <MemoryRouter>
        <OverviewPage />
      </MemoryRouter>
    </QueryClientProvider>,
  );
}

describe("OverviewPage", () => {
  it("renders metrics, attention items, active runs, and project cards", async () => {
    renderPage({
      generated_at: "2026-06-12T00:00:00Z",
      counts: { running: 5, retrying: 0, blocked: 1 },
      running: [
        {
          issue_id: "i1",
          issue_identifier: "HAR-44",
          state: "In Progress",
          worker_host: null,
          workspace_path: null,
          session_id: "s1",
          turn_count: 7,
          last_event: "turn_completed",
          last_message: null,
          started_at: "2026-06-12T00:00:00Z",
          last_event_at: null,
          tokens: { input_tokens: 0, output_tokens: 0, total_tokens: 2000 },
          project: { id: "p1", name: "Alpha", slug: "alpha" },
        },
      ],
      retrying: [],
      blocked: [
        {
          issue_id: "b1",
          issue_identifier: "HAR-42",
          state: "In Progress",
          error: "sandbox denied",
          worker_host: null,
          workspace_path: null,
          session_id: null,
          blocked_at: null,
          last_event: null,
          last_message: null,
          last_event_at: null,
          project: { id: "p1", name: "Alpha", slug: "alpha" },
        },
      ],
      projects: [
        { id: "p1", slug: "alpha", name: "Alpha", counts: { running: 1, retrying: 0, blocked: 1 } },
      ],
    });

    await waitFor(() =>
      expect(screen.getByRole("heading", { name: "Overview" })).toBeInTheDocument(),
    );
    expect(screen.getByText("5")).toBeInTheDocument(); // running metric
    expect(screen.getByText("HAR-42")).toBeInTheDocument(); // needs attention
    expect(screen.getByText("HAR-44")).toBeInTheDocument(); // active runs
    expect(screen.getByRole("heading", { name: "Projects" })).toBeInTheDocument();
  });

  it("surfaces a snapshot error payload", async () => {
    renderPage({
      generated_at: "2026-06-12T00:00:00Z",
      error: { code: "timeout", message: "snapshot timed out" },
    });
    await waitFor(() => expect(screen.getByText("timeout")).toBeInTheDocument());
    expect(screen.getByText("snapshot timed out")).toBeInTheDocument();
  });
});
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `npm run test -- --run src/features/overview/OverviewPage.test.tsx`
Expected: FAIL — cannot resolve `@/features/overview/OverviewPage`.

- [ ] **Step 3: Implement the page**

Create `src/features/overview/OverviewPage.tsx`:

```tsx
import { Alert, AlertDescription, AlertTitle } from "@/components/ui/alert";
import { Skeleton } from "@/components/ui/skeleton";
import { useDashboard } from "@/features/dashboard/useDashboard";
import { ActiveRuns } from "@/features/overview/components/ActiveRuns";
import { MetricCards } from "@/features/overview/components/MetricCards";
import { NeedsAttention } from "@/features/overview/components/NeedsAttention";
import { ProjectHealthGrid } from "@/features/overview/components/ProjectHealthGrid";
import { RecentActivity } from "@/features/overview/components/RecentActivity";

export function OverviewPage() {
  const { data, isLoading } = useDashboard();

  if (isLoading && !data) {
    return (
      <div className="space-y-6">
        <Skeleton className="h-24 w-full" />
        <Skeleton className="h-48 w-full" />
      </div>
    );
  }
  if (!data) return <p className="text-muted-foreground">No data.</p>;

  return (
    <div className="space-y-6">
      <h1 className="text-2xl font-semibold">Overview</h1>

      {data.error ? (
        <Alert variant="destructive">
          <AlertTitle>{data.error.code}</AlertTitle>
          <AlertDescription>{data.error.message}</AlertDescription>
        </Alert>
      ) : null}

      <MetricCards state={data} />
      <NeedsAttention state={data} />
      <ActiveRuns rows={data.running ?? []} />

      <section className="space-y-2">
        <h2 className="text-lg font-medium">Projects</h2>
        <ProjectHealthGrid projects={data.projects ?? []} />
      </section>

      <RecentActivity events={data.durable?.work_events ?? []} />
    </div>
  );
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `npm run test -- --run src/features/overview/OverviewPage.test.tsx`
Expected: PASS.

- [ ] **Step 5: Swap the route and delete the legacy page**

Replace `src/App.tsx` with:

```tsx
import { Routes, Route } from "react-router-dom";
import { AppShell } from "@/components/layout/AppShell";
import { OverviewPage } from "@/features/overview/OverviewPage";
import { ProjectsPage } from "@/routes/ProjectsPage";
import { ProjectFormPage } from "@/routes/ProjectFormPage";
import { NotFoundPage } from "@/routes/NotFoundPage";

export function AppRoutes() {
  return (
    <Routes>
      <Route element={<AppShell />}>
        <Route index element={<OverviewPage />} />
        <Route path="projects" element={<ProjectsPage />} />
        <Route path="projects/new" element={<ProjectFormPage />} />
        <Route path="projects/:id/edit" element={<ProjectFormPage />} />
        <Route path="*" element={<NotFoundPage />} />
      </Route>
    </Routes>
  );
}
```

In `src/App.test.tsx`, update the first test's heading assertion:

```tsx
  it("shows the sidebar nav and the overview at /", () => {
    renderAt("/");
    expect(screen.getByRole("navigation", { name: "Main" })).toBeInTheDocument();
    expect(screen.getByRole("navigation", { name: "Breadcrumb" })).toBeInTheDocument();
    expect(screen.getByRole("heading", { name: "Overview" })).toBeInTheDocument();
  });
```

Delete the superseded files (RuntimeCard/RateLimits stay — Task 9 moves them):

```bash
git rm src/routes/DashboardPage.tsx src/routes/DashboardPage.test.tsx
git rm src/features/dashboard/components/RunningTable.tsx src/features/dashboard/components/RunningTable.test.tsx
git rm src/features/dashboard/components/RetryTable.tsx
git rm src/features/dashboard/components/BlockedTable.tsx
git rm src/features/dashboard/components/ProjectsSummaryTable.tsx
git rm src/features/dashboard/components/WorkRunsTable.tsx src/features/dashboard/components/WorkRunsTable.test.tsx
git rm src/features/dashboard/components/ArtifactsTable.tsx
```

- [ ] **Step 6: Run the full suite, typecheck, and lint**

Run: `npm run test -- --run && npm run typecheck && npm run lint`
Expected: PASS, no unused-import or dead-reference errors.

- [ ] **Step 7: Commit**

```bash
git add -A src
git commit -m "feat(frontend): replace dashboard dump with Overview page"
```

---

### Task 9: RuntimePage

**Files:**
- Move: `src/features/dashboard/components/RuntimeCard.tsx` → `src/features/runtime/components/RuntimeCard.tsx`
- Move: `src/features/dashboard/components/RateLimits.tsx` → `src/features/runtime/components/RateLimits.tsx`
- Create: `src/features/runtime/RuntimePage.tsx`
- Test: `src/features/runtime/RuntimePage.test.tsx`
- Modify: `src/App.tsx` (add route)

- [ ] **Step 1: Move the components**

```bash
mkdir -p src/features/runtime/components
git mv src/features/dashboard/components/RuntimeCard.tsx src/features/runtime/components/RuntimeCard.tsx
git mv src/features/dashboard/components/RateLimits.tsx src/features/runtime/components/RateLimits.tsx
```

(Do not edit their contents — proper rate-limit rendering is Phase 5 polish.)

- [ ] **Step 2: Write the failing page test**

Create `src/features/runtime/RuntimePage.test.tsx`:

```tsx
import { render, screen, waitFor } from "@testing-library/react";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { describe, it, expect, vi, afterEach } from "vitest";
import { RuntimePage } from "@/features/runtime/RuntimePage";

afterEach(() => vi.restoreAllMocks());

function renderPage(statePayload: object) {
  vi.stubGlobal(
    "fetch",
    vi.fn(
      async () =>
        new Response(JSON.stringify(statePayload), {
          status: 200,
          headers: { "content-type": "application/json" },
        }),
    ),
  );
  const qc = new QueryClient({ defaultOptions: { queries: { retry: false } } });
  return render(
    <QueryClientProvider client={qc}>
      <RuntimePage />
    </QueryClientProvider>,
  );
}

describe("RuntimePage", () => {
  it("renders sandbox info and rate limits when present", async () => {
    renderPage({
      generated_at: "2026-06-12T00:00:00Z",
      runtime: {
        sandbox: {
          posture: "bubblewrap",
          bubblewrap_available: true,
          apparmor_restrict_unprivileged_userns: null,
          thread_sandbox: null,
          turn_sandbox_type: null,
          warnings: [],
        },
      },
      rate_limits: { primary: { used_percent: 42 } },
    });

    await waitFor(() =>
      expect(screen.getByRole("heading", { name: "Runtime" })).toBeInTheDocument(),
    );
    expect(screen.getByText(/bubblewrap/)).toBeInTheDocument();
    expect(screen.getByRole("heading", { name: "Rate limits" })).toBeInTheDocument();
  });

  it("renders empty messages when runtime data is absent", async () => {
    renderPage({ generated_at: "2026-06-12T00:00:00Z" });
    await waitFor(() =>
      expect(screen.getByText(/no sandbox info reported/i)).toBeInTheDocument(),
    );
    expect(screen.getByText(/no rate limit data/i)).toBeInTheDocument();
  });
});
```

- [ ] **Step 3: Run the test to verify it fails**

Run: `npm run test -- --run src/features/runtime/RuntimePage.test.tsx`
Expected: FAIL — cannot resolve `@/features/runtime/RuntimePage`.

- [ ] **Step 4: Implement the page and the route**

Create `src/features/runtime/RuntimePage.tsx`:

```tsx
import { Skeleton } from "@/components/ui/skeleton";
import { useDashboard } from "@/features/dashboard/useDashboard";
import { RateLimits } from "@/features/runtime/components/RateLimits";
import { RuntimeCard } from "@/features/runtime/components/RuntimeCard";

export function RuntimePage() {
  const { data, isLoading } = useDashboard();

  if (isLoading && !data) return <Skeleton className="h-48 w-full" />;

  return (
    <div className="space-y-6">
      <h1 className="text-2xl font-semibold">Runtime</h1>

      {data?.runtime?.sandbox ? (
        <RuntimeCard sandbox={data.runtime.sandbox} />
      ) : (
        <p className="text-muted-foreground">No sandbox info reported.</p>
      )}

      <section>
        <h2 className="mb-2 text-lg font-medium">Rate limits</h2>
        {data?.rate_limits != null ? (
          <RateLimits value={data.rate_limits} />
        ) : (
          <p className="text-muted-foreground">No rate limit data.</p>
        )}
      </section>
    </div>
  );
}
```

In `src/App.tsx`, add the import and route:

```tsx
import { RuntimePage } from "@/features/runtime/RuntimePage";
```

```tsx
        <Route path="runtime" element={<RuntimePage />} />
```

(placed directly after the `index` route).

- [ ] **Step 5: Run the suite to verify it passes**

Run: `npm run test -- --run && npm run typecheck`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add -A src
git commit -m "feat(frontend): add runtime page for sandbox and rate limits"
```

---

### Task 10: Designed 404 page

**Files:**
- Rewrite: `src/routes/NotFoundPage.tsx`

- [ ] **Step 1: Rewrite the page**

Replace `src/routes/NotFoundPage.tsx` with:

```tsx
import { Link } from "react-router-dom";

export function NotFoundPage() {
  return (
    <div className="flex min-h-[50vh] flex-col items-center justify-center gap-3 text-center">
      <p className="font-mono text-5xl font-semibold text-muted-foreground">404</p>
      <h1 className="text-xl font-medium">Page not found</h1>
      <p className="text-sm text-muted-foreground">
        The page you are looking for does not exist or has moved.
      </p>
      <Link to="/" className="text-sm underline underline-offset-4 hover:text-foreground">
        Back to Overview
      </Link>
    </div>
  );
}
```

- [ ] **Step 2: Verify the existing route test still passes**

Run: `npm run test -- --run src/App.test.tsx`
Expected: PASS — the `/nope` test matches `/not found/i` against "Page not found".

- [ ] **Step 3: Commit**

```bash
git add src/routes/NotFoundPage.tsx
git commit -m "feat(frontend): design the 404 page"
```

---

### Task 11: E2E, docs, and full verification

**Files:**
- Modify: `e2e/react-spa.spec.ts`
- Modify: `CLAUDE.md` (in `elixir/assets/`)

- [ ] **Step 1: Update the e2e spec**

Replace `e2e/react-spa.spec.ts` with:

```ts
import { expect, test } from "@playwright/test";

test("overview renders React data from REST and channel", async ({ page }) => {
  await page.goto("/");

  await expect(page.getByRole("heading", { name: "Overview" })).toBeVisible();
  await expect(page.getByText("COD-1")).toBeVisible();
  await expect(page.getByText("Live")).toBeVisible();

  await page.request.post("/api/v1/refresh");
  await expect(page.getByText("COD-2")).toBeVisible();
});

test("projects route is owned by the React router", async ({ page }) => {
  await page.goto("/projects");

  await expect(page.getByRole("heading", { name: "Projects" })).toBeVisible();
  await expect(page.getByRole("main").getByRole("link", { name: "New project" })).toBeVisible();
});

test("runtime route is owned by the React router", async ({ page }) => {
  await page.goto("/runtime");

  await expect(page.getByRole("heading", { name: "Runtime" })).toBeVisible();
});
```

Notes: the artifact-path assertions are intentionally removed — artifacts have no UI
home until Phase 4 (Evidence tab) restores them. The "New project" locator is scoped
to `main` because the sidebar adds a second link (`Create project`).

- [ ] **Step 2: Run the e2e harness**

Run (from `elixir/`): `make e2e`
Expected: 3 passed. If `COD-1` is not visible, check that the e2e fixture state
(`lib/mix/tasks/harmony.react_spa_e2e_server.ex`) still emits running entries — the
Overview shows them in the "Active runs" table.

- [ ] **Step 3: Update the frontend agent guide**

In `elixir/assets/CLAUDE.md`, replace the "Routing note" section's last sentence with:

```markdown
The Phase 3 cutover is complete: Vite builds with `base: "/"`, Phoenix serves `priv/static/app`
from `/`, and React Router owns `/` (Overview), `/runtime`, `/projects`, `/projects/new`, and
`/projects/:id/edit`. The shell is a project sidebar (`src/components/layout/Sidebar.tsx`) +
breadcrumb header; page features live under `src/features/{overview,runtime,projects}/`.
```

- [ ] **Step 4: Full verification**

Run (from `elixir/assets/`): `npm run test -- --run && npm run typecheck && npm run lint && npm run build`
Run (from `elixir/`): `make e2e`
Expected: everything green.

- [ ] **Step 5: Commit**

```bash
git add e2e/react-spa.spec.ts CLAUDE.md
git commit -m "test(e2e): cover overview shell and runtime route"
```
