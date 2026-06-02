# React Migration Review Fixes Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close the remaining React migration review findings so the branch satisfies the React + WebSockets spec and has reliable local gates.

**Architecture:** Keep the completed Phoenix cutover intact: React remains the only UI at `/`, project CRUD remains REST-backed, and dashboard state remains hydrated through `Presenter.state_payload/0`. Fix the gaps in small slices: stabilize Vitest, restore missing dashboard data, expose real channel connection state, harden project-form error mapping, add contract drift coverage, and replace the stale `make e2e` target with a deterministic React browser E2E.

**Tech Stack:** Elixir 1.19 / OTP 28, Phoenix 1.8, ExUnit, Vite 8, React 19, React Router 7, TanStack Query 5, Phoenix Channels, React Hook Form, Yup, Vitest, React Testing Library, Playwright.

---

## Source Documents

- Spec: `docs/superpowers/specs/2026-06-02-react-websockets-frontend-design.md`
- Prior plans:
  - `docs/superpowers/plans/2026-06-02-00-react-frontend-plan-index.md`
  - `docs/superpowers/plans/2026-06-02-01-react-toolchain-shell.md`
  - `docs/superpowers/plans/2026-06-02-02-react-dashboard-realtime.md`
  - `docs/superpowers/plans/2026-06-02-03-react-projects-crud.md`
  - `docs/superpowers/plans/2026-06-02-04-react-cutover-cleanup.md`

## File Structure

- Modify: `elixir/assets/vite.config.ts` — stabilize Vitest worker pool for the local Node/jsdom stack.
- Modify: `elixir/assets/src/routes/DashboardPage.tsx` — merge runtime and durable artifacts and pass real connection state.
- Modify: `elixir/assets/src/features/dashboard/components/ArtifactsTable.tsx` — accept runtime and durable artifact shapes.
- Modify: `elixir/assets/src/features/dashboard/components/ConnectionStatus.tsx` — render `connecting`, `live`, `reconnecting`, and `offline`.
- Modify: `elixir/assets/src/lib/socket.ts` — publish channel lifecycle state to React.
- Create: `elixir/assets/src/lib/dashboardConnection.tsx` — React context for dashboard channel connection state.
- Modify: `elixir/assets/src/providers/AppProviders.tsx` — mount dashboard connection provider.
- Modify: `elixir/assets/src/routes/ProjectFormPage.tsx` — map server `config` errors to the JSON textarea.
- Modify: `elixir/assets/src/types/contract.ts` — fully model durable payload lists instead of hiding them behind `[key: string]: unknown`.
- Create: `elixir/assets/src/test/fixtures/state_payload.fixture.json` — golden dashboard payload shared by TypeScript contract tests.
- Create: `elixir/assets/src/types/contract.test.ts` — compile/runtime smoke test for the golden payload.
- Create: `elixir/lib/mix/tasks/harmony.react_spa_e2e_server.ex` — deterministic local Phoenix server for browser E2E.
- Create: `elixir/assets/playwright.config.ts` — Playwright config with a Phoenix web server command.
- Create: `elixir/assets/e2e/react-spa.spec.ts` — browser assertions for React dashboard, projects route, and channel update.
- Modify: `elixir/assets/package.json`, `elixir/assets/package-lock.json` — add Playwright scripts/dependency.
- Modify: `elixir/Makefile` — make `make e2e` drive the React SPA browser harness and preserve the old real Linear/Codex E2E under `make live-e2e`.
- Modify: `elixir/assets/CLAUDE.md`, `elixir/assets/AGENTS.md`, `elixir/lib/symphony_elixir_web/controllers/spa_controller.ex` — remove stale `/app` text after Phase 3 cutover.

---

### Task 1: Stabilize The Frontend Gate

**Files:**
- Modify: `elixir/assets/vite.config.ts`
- Test: `elixir/assets/src/App.test.tsx`

- [ ] **Step 1: Reproduce the current frontend gate failure**

Run from `elixir/assets/`:

```bash
npm run lint && npm run test -- --run && npm run build
```

Expected before this task: `eslint` exits 0, then Vitest fails while loading `src/App.test.tsx` with a worker/jsdom/aria-query stack trace. `npm run build` does not run because the command chain stops at Vitest.

- [ ] **Step 2: Force Vitest onto a single thread pool**

Replace the `test` block in `elixir/assets/vite.config.ts` with this exact block:

```ts
  test: {
    environment: "jsdom",
    globals: true,
    setupFiles: "./src/test/setup.ts",
    css: true,
    pool: "threads",
    poolOptions: {
      threads: {
        singleThread: true,
      },
    },
  },
```

This keeps the test environment as jsdom, but avoids the current fork-worker path that crashes before the React route tests can run.

- [ ] **Step 3: Verify the frontend gate is green**

Run from `elixir/assets/`:

```bash
npm run lint && npm run test -- --run && npm run build
```

Expected: `eslint` exits 0, Vitest reports every test file passing, and Vite writes `../priv/static/app/index.html`.

- [ ] **Step 4: Commit**

```bash
cd /work/Projekty/Harmony
git add elixir/assets/vite.config.ts
git commit -m "test(frontend): stabilize Vitest worker pool"
```

---

### Task 2: Render Runtime And Durable Artifacts

**Files:**
- Modify: `elixir/assets/src/routes/DashboardPage.tsx`
- Modify: `elixir/assets/src/features/dashboard/components/ArtifactsTable.tsx`
- Test: `elixir/assets/src/routes/DashboardPage.test.tsx`

- [ ] **Step 1: Add a failing dashboard test for top-level runtime artifacts**

Append this test to `elixir/assets/src/routes/DashboardPage.test.tsx`:

```tsx
it("renders runtime artifacts from the top-level state payload", async () => {
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
            artifacts: [{ kind: "screenshot", path: ".harmony/artifacts/runtime.png" }],
          }),
          { status: 200, headers: { "content-type": "application/json" } },
        ),
    ),
  );

  renderPage();

  expect(await screen.findByText("Evidence artifacts")).toBeInTheDocument();
  expect(screen.getByText("screenshot")).toBeInTheDocument();
  expect(screen.getByText(".harmony/artifacts/runtime.png")).toBeInTheDocument();
});
```

- [ ] **Step 2: Run the test to verify it fails**

Run from `elixir/assets/`:

```bash
npm run test -- --run src/routes/DashboardPage.test.tsx
```

Expected before implementation: FAIL because `DashboardPage` only renders `data.durable?.artifacts` and ignores top-level `data.artifacts`.

- [ ] **Step 3: Update `ArtifactsTable` to accept both artifact shapes**

Replace `elixir/assets/src/features/dashboard/components/ArtifactsTable.tsx` with:

```tsx
import {
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from "@/components/ui/table";

export interface EvidenceArtifact {
  id?: string | null;
  kind?: string | null;
  path?: string | null;
}

export function ArtifactsTable({ rows }: { rows: EvidenceArtifact[] }) {
  if (rows.length === 0) return <p className="text-muted-foreground">No artifacts.</p>;

  return (
    <Table>
      <TableHeader>
        <TableRow>
          <TableHead>Kind</TableHead>
          <TableHead>Path</TableHead>
        </TableRow>
      </TableHeader>
      <TableBody>
        {rows.map((a, i) => (
          <TableRow key={a.id ?? `${a.kind ?? "artifact"}-${a.path ?? "path"}-${i}`}>
            <TableCell>{a.kind ?? "artifact"}</TableCell>
            <TableCell className="max-w-md truncate">{a.path ?? "n/a"}</TableCell>
          </TableRow>
        ))}
      </TableBody>
    </Table>
  );
}
```

- [ ] **Step 4: Merge runtime and durable artifacts in `DashboardPage`**

Inside `DashboardPage`, immediately after `const nowMs = useNow();`, add:

```tsx
  const evidenceArtifacts = [...(data?.artifacts ?? []), ...(data?.durable?.artifacts ?? [])];
```

Then replace the current durable-artifacts section:

```tsx
          {data.durable?.artifacts ? (
            <section>
              <h2 className="text-lg font-medium mb-2">Evidence artifacts</h2>
              <ArtifactsTable rows={data.durable.artifacts} />
            </section>
          ) : null}
```

with:

```tsx
          <section>
            <h2 className="text-lg font-medium mb-2">Evidence artifacts</h2>
            <ArtifactsTable rows={evidenceArtifacts} />
          </section>
```

- [ ] **Step 5: Verify the focused dashboard test passes**

Run from `elixir/assets/`:

```bash
npm run test -- --run src/routes/DashboardPage.test.tsx
```

Expected: PASS.

- [ ] **Step 6: Run the frontend gate**

Run from `elixir/assets/`:

```bash
npm run lint && npm run test -- --run && npm run build
```

Expected: all three commands exit 0.

- [ ] **Step 7: Commit**

```bash
cd /work/Projekty/Harmony
git add elixir/assets/src/routes/DashboardPage.tsx \
        elixir/assets/src/routes/DashboardPage.test.tsx \
        elixir/assets/src/features/dashboard/components/ArtifactsTable.tsx
git commit -m "fix(frontend): show runtime dashboard artifacts"
```

---

### Task 3: Track And Render Channel Connection State

**Files:**
- Create: `elixir/assets/src/lib/dashboardConnection.tsx`
- Modify: `elixir/assets/src/lib/socket.ts`
- Modify: `elixir/assets/src/providers/AppProviders.tsx`
- Modify: `elixir/assets/src/features/dashboard/components/ConnectionStatus.tsx`
- Modify: `elixir/assets/src/routes/DashboardPage.tsx`
- Test: `elixir/assets/src/lib/socket.test.ts`
- Create: `elixir/assets/src/features/dashboard/components/ConnectionStatus.test.tsx`

- [ ] **Step 1: Extend the socket test with channel lifecycle callbacks**

Replace `elixir/assets/src/lib/socket.test.ts` with:

```ts
import { describe, it, expect, vi } from "vitest";
import { QueryClient } from "@tanstack/react-query";
import { hydrateFromChannel, DASHBOARD_KEY } from "@/lib/socket";

function fakeChannel() {
  const handlers: Record<string, (payload: unknown) => void> = {};
  let joinOk: ((resp: unknown) => void) | undefined;
  let joinError: ((resp: unknown) => void) | undefined;
  let joinTimeout: ((resp: unknown) => void) | undefined;
  let errorHandler: (() => void) | undefined;
  let closeHandler: (() => void) | undefined;

  const channel = {
    on: (event: string, cb: (payload: unknown) => void) => {
      handlers[event] = cb;
      return 0;
    },
    onError: (cb: () => void) => {
      errorHandler = cb;
    },
    onClose: (cb: () => void) => {
      closeHandler = cb;
    },
    join: () => ({
      receive(status: string, cb: (resp: unknown) => void) {
        if (status === "ok") joinOk = cb;
        if (status === "error") joinError = cb;
        if (status === "timeout") joinTimeout = cb;
        return this;
      },
    }),
    leave: vi.fn(() => ({ receive: () => undefined })),
  };

  return {
    channel,
    handlers,
    emitJoinOk: (resp: unknown) => joinOk?.(resp),
    emitJoinError: () => joinError?.({}),
    emitJoinTimeout: () => joinTimeout?.({}),
    emitError: () => errorHandler?.(),
    emitClose: () => closeHandler?.(),
  };
}

describe("channel hydration", () => {
  it("writes join state and pushed state into the query cache", () => {
    const qc = new QueryClient();
    const fake = fakeChannel();

    const cleanup = hydrateFromChannel(qc, fake.channel as never);
    fake.emitJoinOk({ state: { generated_at: "join" } });
    expect(qc.getQueryData(DASHBOARD_KEY)).toEqual({ generated_at: "join" });

    fake.handlers["state"]({ generated_at: "push" });
    expect(qc.getQueryData(DASHBOARD_KEY)).toEqual({ generated_at: "push" });

    cleanup();
    expect(fake.channel.leave).toHaveBeenCalled();
  });

  it("reports connection lifecycle states", () => {
    const qc = new QueryClient();
    const fake = fakeChannel();
    const onStatus = vi.fn();

    hydrateFromChannel(qc, fake.channel as never, { onStatus });

    expect(onStatus).toHaveBeenCalledWith("connecting");
    fake.emitJoinOk({ state: { generated_at: "join" } });
    expect(onStatus).toHaveBeenCalledWith("live");
    fake.emitError();
    expect(onStatus).toHaveBeenCalledWith("reconnecting");
    fake.emitClose();
    expect(onStatus).toHaveBeenCalledWith("offline");
  });
});
```

- [ ] **Step 2: Add a focused status component test**

Create `elixir/assets/src/features/dashboard/components/ConnectionStatus.test.tsx`:

```tsx
import { render, screen } from "@testing-library/react";
import { describe, it, expect } from "vitest";
import { ConnectionStatus } from "@/features/dashboard/components/ConnectionStatus";
import { DashboardConnectionProvider } from "@/lib/dashboardConnection";

function renderStatus(status: "connecting" | "live" | "reconnecting" | "offline") {
  render(
    <DashboardConnectionProvider initialStatus={status}>
      <ConnectionStatus />
    </DashboardConnectionProvider>,
  );
}

describe("ConnectionStatus", () => {
  it("renders reconnecting when the channel reports an error after data was loaded", () => {
    renderStatus("reconnecting");
    expect(screen.getByText("Reconnecting…")).toBeInTheDocument();
  });

  it("renders offline when the channel closes", () => {
    renderStatus("offline");
    expect(screen.getByText("Offline")).toBeInTheDocument();
  });
});
```

- [ ] **Step 3: Run tests to verify they fail**

Run from `elixir/assets/`:

```bash
npm run test -- --run src/lib/socket.test.ts src/features/dashboard/components/ConnectionStatus.test.tsx
```

Expected before implementation: FAIL because `hydrateFromChannel` does not accept lifecycle callbacks and `dashboardConnection.tsx` does not exist.

- [ ] **Step 4: Create the connection-state context**

Create `elixir/assets/src/lib/dashboardConnection.tsx`:

```tsx
import { createContext, useContext, useState, type ReactNode } from "react";

export type DashboardConnectionStatus = "connecting" | "live" | "reconnecting" | "offline";

interface DashboardConnectionValue {
  status: DashboardConnectionStatus;
  setStatus: (status: DashboardConnectionStatus) => void;
}

const DashboardConnectionContext = createContext<DashboardConnectionValue | null>(null);

export function DashboardConnectionProvider({
  children,
  initialStatus = "connecting",
}: {
  children: ReactNode;
  initialStatus?: DashboardConnectionStatus;
}) {
  const [status, setStatus] = useState<DashboardConnectionStatus>(initialStatus);

  return (
    <DashboardConnectionContext.Provider value={{ status, setStatus }}>
      {children}
    </DashboardConnectionContext.Provider>
  );
}

export function useDashboardConnection() {
  const context = useContext(DashboardConnectionContext);
  if (!context) {
    throw new Error("useDashboardConnection must be used inside DashboardConnectionProvider");
  }
  return context;
}
```

- [ ] **Step 5: Update socket lifecycle handling**

In `elixir/assets/src/lib/socket.ts`, update the imports:

```ts
import type { DashboardConnectionStatus } from "@/lib/dashboardConnection";
```

Replace `hydrateFromChannel` with:

```ts
interface HydrationOptions {
  onStatus?: (status: DashboardConnectionStatus) => void;
}

export function hydrateFromChannel(
  queryClient: QueryClient,
  channel: Channel,
  opts: HydrationOptions = {},
): () => void {
  opts.onStatus?.("connecting");

  channel.on("state", (payload: StatePayload) => {
    queryClient.setQueryData(DASHBOARD_KEY, payload);
    opts.onStatus?.("live");
  });

  channel.onError(() => {
    opts.onStatus?.("reconnecting");
  });

  channel.onClose(() => {
    opts.onStatus?.("offline");
  });

  channel
    .join()
    .receive("ok", (resp: { state: StatePayload }) => {
      queryClient.setQueryData(DASHBOARD_KEY, resp.state);
      opts.onStatus?.("live");
    })
    .receive("error", () => {
      opts.onStatus?.("offline");
    })
    .receive("timeout", () => {
      opts.onStatus?.("offline");
    });

  return () => {
    channel.leave();
  };
}
```

Replace `useDashboardChannel` with:

```ts
/** Open the dashboard channel for the lifetime of the component tree. */
export function useDashboardChannel(
  queryClient: QueryClient,
  onStatus?: (status: DashboardConnectionStatus) => void,
): void {
  useEffect(() => {
    const socket = createSocket();
    const channel = socket.channel("observability:dashboard", {});
    const cleanup = hydrateFromChannel(queryClient, channel, { onStatus });
    return () => {
      cleanup();
      socket.disconnect();
    };
  }, [queryClient, onStatus]);
}
```

- [ ] **Step 6: Wire the provider into `AppProviders`**

Replace `elixir/assets/src/providers/AppProviders.tsx` with:

```tsx
import { QueryClientProvider } from "@tanstack/react-query";
import type { ReactNode } from "react";
import { queryClient } from "@/lib/queryClient";
import { useDashboardChannel } from "@/lib/socket";
import { ErrorBoundary } from "@/components/ErrorBoundary";
import { Toaster } from "@/components/ui/sonner";
import { DashboardConnectionProvider, useDashboardConnection } from "@/lib/dashboardConnection";

function ChannelBridge({ children }: { children: ReactNode }) {
  const { setStatus } = useDashboardConnection();
  useDashboardChannel(queryClient, setStatus);
  return <>{children}</>;
}

export function AppProviders({ children }: { children: ReactNode }) {
  return (
    <ErrorBoundary>
      <QueryClientProvider client={queryClient}>
        <DashboardConnectionProvider>
          <ChannelBridge>{children}</ChannelBridge>
        </DashboardConnectionProvider>
        <Toaster />
      </QueryClientProvider>
    </ErrorBoundary>
  );
}
```

- [ ] **Step 7: Update the status badge component**

Replace `elixir/assets/src/features/dashboard/components/ConnectionStatus.tsx` with:

```tsx
import { Badge } from "@/components/ui/badge";
import { useDashboardConnection } from "@/lib/dashboardConnection";

export function ConnectionStatus() {
  const { status } = useDashboardConnection();

  if (status === "live") return <Badge variant="secondary">Live</Badge>;
  if (status === "reconnecting") return <Badge variant="outline">Reconnecting…</Badge>;
  if (status === "offline") return <Badge variant="outline">Offline</Badge>;
  return <Badge variant="outline">Connecting…</Badge>;
}
```

In `elixir/assets/src/routes/DashboardPage.tsx`, replace:

```tsx
        <ConnectionStatus hasData={!!data} />
```

with:

```tsx
        <ConnectionStatus />
```

- [ ] **Step 8: Verify focused tests pass**

Run from `elixir/assets/`:

```bash
npm run test -- --run src/lib/socket.test.ts src/features/dashboard/components/ConnectionStatus.test.tsx
```

Expected: PASS.

- [ ] **Step 9: Run the frontend gate**

Run from `elixir/assets/`:

```bash
npm run lint && npm run test -- --run && npm run build
```

Expected: all three commands exit 0.

- [ ] **Step 10: Commit**

```bash
cd /work/Projekty/Harmony
git add elixir/assets/src/lib/socket.ts \
        elixir/assets/src/lib/socket.test.ts \
        elixir/assets/src/lib/dashboardConnection.tsx \
        elixir/assets/src/providers/AppProviders.tsx \
        elixir/assets/src/features/dashboard/components/ConnectionStatus.tsx \
        elixir/assets/src/features/dashboard/components/ConnectionStatus.test.tsx \
        elixir/assets/src/routes/DashboardPage.tsx
git commit -m "fix(frontend): track dashboard channel connection state"
```

---

### Task 4: Map Project Form Server Errors To Visible Fields

**Files:**
- Modify: `elixir/assets/src/routes/ProjectFormPage.tsx`
- Test: `elixir/assets/src/routes/ProjectFormPage.test.tsx`

- [ ] **Step 1: Add a failing test for backend `config` field errors**

Append this test to `elixir/assets/src/routes/ProjectFormPage.test.tsx`:

```tsx
it("maps a server config error onto the JSON textarea field", async () => {
  vi.stubGlobal(
    "fetch",
    vi.fn(
      async () =>
        new Response(
          JSON.stringify({
            error: {
              code: "validation_failed",
              message: "Validation failed",
              fields: { config: ["must be a JSON object"] },
            },
          }),
          { status: 422, headers: { "content-type": "application/json" } },
        ),
    ),
  );

  renderForm();
  await userEvent.type(screen.getByLabelText("Slug"), "portal");
  await userEvent.type(screen.getByLabelText("GitHub owner"), "dezet");
  await userEvent.type(screen.getByLabelText("GitHub repo"), "portal");
  await userEvent.type(screen.getByLabelText("Base branch"), "main");
  await userEvent.click(screen.getByRole("button", { name: /save/i }));

  expect(await screen.findByText("must be a JSON object")).toBeInTheDocument();
  expect(screen.getByLabelText("Config (JSON)")).toHaveAccessibleDescription(
    "must be a JSON object",
  );
});
```

- [ ] **Step 2: Run the test to verify it fails**

Run from `elixir/assets/`:

```bash
npm run test -- --run src/routes/ProjectFormPage.test.tsx
```

Expected before implementation: FAIL because server field `config` is passed to RHF as `config`, but the form field is named `config_json`.

- [ ] **Step 3: Add stable error ids and server-field mapping**

In `elixir/assets/src/routes/ProjectFormPage.tsx`, add this helper below `FIELDS`:

```tsx
function serverFieldToFormField(field: string): keyof ProjectFormValues {
  if (field === "config") return "config_json";
  return field as keyof ProjectFormValues;
}

function errorId(field: string) {
  return `${field}-error`;
}
```

Replace the server error loop:

```tsx
        for (const [field, messages] of Object.entries(err.fields)) {
          setError(field as keyof ProjectFormValues, { message: messages.join(", ") });
        }
```

with:

```tsx
        for (const [field, messages] of Object.entries(err.fields)) {
          setError(serverFieldToFormField(field), { message: messages.join(", ") });
        }
```

In the mapped text fields, replace:

```tsx
          <Input id={f.name} {...register(f.name)} />
          {errors[f.name] ? (
            <p className="text-sm text-destructive">{errors[f.name]?.message}</p>
          ) : null}
```

with:

```tsx
          <Input
            id={f.name}
            aria-describedby={errors[f.name] ? errorId(f.name) : undefined}
            {...register(f.name)}
          />
          {errors[f.name] ? (
            <p id={errorId(f.name)} className="text-sm text-destructive">
              {errors[f.name]?.message}
            </p>
          ) : null}
```

For `config_version`, replace:

```tsx
        <Input id="config_version" type="number" {...register("config_version")} />
        {errors.config_version ? (
          <p className="text-sm text-destructive">{errors.config_version.message}</p>
        ) : null}
```

with:

```tsx
        <Input
          id="config_version"
          type="number"
          aria-describedby={errors.config_version ? errorId("config_version") : undefined}
          {...register("config_version")}
        />
        {errors.config_version ? (
          <p id={errorId("config_version")} className="text-sm text-destructive">
            {errors.config_version.message}
          </p>
        ) : null}
```

For `config_json`, replace:

```tsx
        <Textarea id="config_json" rows={8} {...register("config_json")} />
        {errors.config_json ? (
          <p className="text-sm text-destructive">{errors.config_json.message}</p>
        ) : null}
```

with:

```tsx
        <Textarea
          id="config_json"
          rows={8}
          aria-describedby={errors.config_json ? errorId("config_json") : undefined}
          {...register("config_json")}
        />
        {errors.config_json ? (
          <p id={errorId("config_json")} className="text-sm text-destructive">
            {errors.config_json.message}
          </p>
        ) : null}
```

- [ ] **Step 4: Verify focused form tests pass**

Run from `elixir/assets/`:

```bash
npm run test -- --run src/routes/ProjectFormPage.test.tsx
```

Expected: PASS.

- [ ] **Step 5: Run the frontend gate**

Run from `elixir/assets/`:

```bash
npm run lint && npm run test -- --run && npm run build
```

Expected: all three commands exit 0.

- [ ] **Step 6: Commit**

```bash
cd /work/Projekty/Harmony
git add elixir/assets/src/routes/ProjectFormPage.tsx \
        elixir/assets/src/routes/ProjectFormPage.test.tsx
git commit -m "fix(frontend): map project config validation errors"
```

---

### Task 5: Add TypeScript Contract Coverage For Durable Payloads

**Files:**
- Modify: `elixir/assets/src/types/contract.ts`
- Create: `elixir/assets/src/test/fixtures/state_payload.fixture.json`
- Create: `elixir/assets/src/types/contract.test.ts`
- Modify: `elixir/assets/tsconfig.app.json`

- [ ] **Step 1: Enable JSON fixture imports**

In `elixir/assets/tsconfig.app.json`, inside `compilerOptions`, add these entries if they are not already present:

```json
    "resolveJsonModule": true,
    "allowSyntheticDefaultImports": true,
```

- [ ] **Step 2: Create the golden state payload fixture**

Create `elixir/assets/src/test/fixtures/state_payload.fixture.json`:

```json
{
  "generated_at": "2026-06-02T00:00:00Z",
  "counts": { "running": 1, "retrying": 1, "blocked": 1 },
  "running": [
    {
      "issue_id": "issue-1",
      "issue_identifier": "COD-1",
      "state": "In Progress",
      "worker_host": null,
      "workspace_path": "/tmp/workspaces/COD-1",
      "session_id": "session-1",
      "turn_count": 2,
      "last_event": "turn.completed",
      "last_message": "done",
      "started_at": "2026-06-02T00:00:00Z",
      "last_event_at": "2026-06-02T00:01:00Z",
      "tokens": { "input_tokens": 10, "output_tokens": 20, "total_tokens": 30 },
      "project": { "id": "project-1", "name": "Roadmap", "slug": "roadmap" }
    }
  ],
  "retrying": [
    {
      "issue_id": "issue-2",
      "issue_identifier": "COD-2",
      "attempt": 2,
      "due_at": "2026-06-02T00:05:00Z",
      "error": "rate limited",
      "worker_host": null,
      "workspace_path": "/tmp/workspaces/COD-2",
      "project": { "id": "project-1", "name": "Roadmap", "slug": "roadmap" }
    }
  ],
  "blocked": [
    {
      "issue_id": "issue-3",
      "issue_identifier": "COD-3",
      "state": "Blocked",
      "error": "approval required",
      "worker_host": null,
      "workspace_path": "/tmp/workspaces/COD-3",
      "session_id": "session-3",
      "blocked_at": "2026-06-02T00:02:00Z",
      "last_event": "approval.required",
      "last_message": "needs approval",
      "last_event_at": "2026-06-02T00:02:30Z",
      "project": { "id": "project-1", "name": "Roadmap", "slug": "roadmap" }
    }
  ],
  "runtime": {
    "sandbox": {
      "posture": "workspace_sandbox_requested",
      "bubblewrap_available": true,
      "apparmor_restrict_unprivileged_userns": 1,
      "thread_sandbox": "workspace-write",
      "turn_sandbox_type": "workspaceWrite",
      "warnings": []
    }
  },
  "artifacts": [{ "kind": "screenshot", "path": ".harmony/artifacts/runtime.png" }],
  "codex_totals": {
    "input_tokens": 10,
    "output_tokens": 20,
    "total_tokens": 30,
    "seconds_running": 60
  },
  "rate_limits": { "remaining": 42 },
  "projects": [
    {
      "id": "project-1",
      "name": "Roadmap",
      "slug": "roadmap",
      "counts": { "running": 1, "retrying": 1, "blocked": 1 }
    }
  ],
  "durable": {
    "projects": [
      {
        "id": "project-1",
        "slug": "roadmap",
        "linear": {
          "project_slug": "roadmap-linear",
          "team_key": "COD",
          "human_review_state": "Human Review"
        },
        "github": {
          "owner": "dezet",
          "repo": "roadmap",
          "base_branch": "develop"
        },
        "config_version": 1
      }
    ],
    "work_runs": [
      {
        "id": "run-1",
        "project_id": "project-1",
        "type": "implementation",
        "status": "queued",
        "dedupe_key": "linear:issue-1",
        "github_owner": "dezet",
        "github_repo": "roadmap",
        "github_pr_number": 17,
        "github_head_sha": "abc123",
        "github_head_ref": "cod-1",
        "github_base_ref": "develop",
        "linear_issue_id": "issue-1",
        "linear_identifier": "COD-1",
        "linear_url": "https://linear.test/COD-1",
        "agent_backend": "codex",
        "payload": { "project_id": "project-1" }
      }
    ],
    "pull_request_links": [
      {
        "id": "link-1",
        "project_id": "project-1",
        "github_owner": "dezet",
        "github_repo": "roadmap",
        "github_pr_number": 17,
        "github_head_sha": "abc123",
        "github_head_ref": "cod-1",
        "github_base_ref": "develop",
        "linear_issue_id": "issue-1",
        "linear_identifier": "COD-1",
        "linear_url": "https://linear.test/COD-1",
        "metadata": { "title": "COD-1 roadmap" }
      }
    ],
    "blockers": [
      {
        "id": "blocker-1",
        "project_id": "project-1",
        "work_run_id": "run-1",
        "target_type": "linear_issue",
        "target_id": "issue-1",
        "reason": "missing_required_evidence:browser",
        "status": "open",
        "metadata": { "required_evidence": ["browser"] }
      }
    ],
    "dedupe_keys": [
      {
        "id": "dedupe-1",
        "project_id": "project-1",
        "key": "linear:issue-1",
        "scope": "implementation",
        "status": "active",
        "metadata": {}
      }
    ],
    "work_events": [
      {
        "id": "event-1",
        "project_id": "project-1",
        "work_run_id": "run-1",
        "type": "linear_state_updated",
        "payload": { "state": "Human Review" },
        "inserted_at": "2026-06-02T00:03:00Z"
      }
    ],
    "artifacts": [
      {
        "id": "artifact-1",
        "project_id": "project-1",
        "work_run_id": "run-1",
        "kind": "screenshot",
        "path": ".harmony/artifacts/durable.png",
        "metadata": { "description": "Durable screenshot" }
      }
    ]
  }
}
```

- [ ] **Step 3: Expand durable contract types**

In `elixir/assets/src/types/contract.ts`, replace `DurableWorkRun`, `DurableArtifact`, and `Durable` with:

```ts
export interface DurableProject {
  id: string;
  slug: string;
  linear: {
    project_slug: string | null;
    team_key: string | null;
    human_review_state: string | null;
  };
  github: {
    owner: string;
    repo: string;
    base_branch: string;
  };
  config_version: number;
}

export interface DurableWorkRun {
  id: string;
  project_id: string;
  type: string;
  status: string;
  dedupe_key: string | null;
  github_owner: string | null;
  github_repo: string | null;
  github_pr_number: number | null;
  github_head_sha: string | null;
  github_head_ref: string | null;
  github_base_ref: string | null;
  linear_issue_id: string | null;
  linear_identifier: string | null;
  linear_url: string | null;
  agent_backend: string | null;
  payload: Record<string, unknown> | null;
}

export interface DurablePullRequestLink {
  id: string;
  project_id: string;
  github_owner: string;
  github_repo: string;
  github_pr_number: number;
  github_head_sha: string | null;
  github_head_ref: string | null;
  github_base_ref: string | null;
  linear_issue_id: string | null;
  linear_identifier: string | null;
  linear_url: string | null;
  metadata: Record<string, unknown> | null;
}

export interface DurableBlocker {
  id: string;
  project_id: string | null;
  work_run_id: string | null;
  target_type: string;
  target_id: string;
  reason: string;
  status: string;
  metadata: Record<string, unknown> | null;
}

export interface DurableDedupeKey {
  id: string;
  project_id: string | null;
  key: string;
  scope: string;
  status: string;
  metadata: Record<string, unknown> | null;
}

export interface DurableWorkEvent {
  id: string;
  project_id: string | null;
  work_run_id: string | null;
  type: string;
  payload: Record<string, unknown> | null;
  inserted_at: string | null;
}

export interface DurableArtifact {
  id: string;
  project_id: string | null;
  work_run_id: string | null;
  kind: string | null;
  path: string | null;
  metadata: Record<string, unknown> | null;
}

export interface Durable {
  projects?: DurableProject[];
  work_runs?: DurableWorkRun[];
  pull_request_links?: DurablePullRequestLink[];
  blockers?: DurableBlocker[];
  dedupe_keys?: DurableDedupeKey[];
  work_events?: DurableWorkEvent[];
  artifacts?: DurableArtifact[];
}
```

- [ ] **Step 4: Add a TypeScript contract test**

Create `elixir/assets/src/types/contract.test.ts`:

```ts
import { describe, expect, it } from "vitest";
import fixture from "@/test/fixtures/state_payload.fixture.json";
import type { StatePayload } from "@/types/contract";

describe("StatePayload contract fixture", () => {
  it("type-checks and exposes all durable lists used by the backend presenter", () => {
    const payload: StatePayload = fixture;

    expect(payload.running?.[0]?.issue_identifier).toBe("COD-1");
    expect(payload.artifacts?.[0]?.path).toBe(".harmony/artifacts/runtime.png");
    expect(payload.durable?.projects?.[0]?.github.base_branch).toBe("develop");
    expect(payload.durable?.pull_request_links?.[0]?.github_pr_number).toBe(17);
    expect(payload.durable?.blockers?.[0]?.reason).toBe("missing_required_evidence:browser");
    expect(payload.durable?.dedupe_keys?.[0]?.key).toBe("linear:issue-1");
    expect(payload.durable?.work_events?.[0]?.type).toBe("linear_state_updated");
    expect(payload.durable?.artifacts?.[0]?.metadata?.description).toBe("Durable screenshot");
  });
});
```

- [ ] **Step 5: Verify the contract test passes**

Run from `elixir/assets/`:

```bash
npm run test -- --run src/types/contract.test.ts
```

Expected: PASS.

- [ ] **Step 6: Run the frontend gate**

Run from `elixir/assets/`:

```bash
npm run lint && npm run test -- --run && npm run build
```

Expected: all three commands exit 0.

- [ ] **Step 7: Commit**

```bash
cd /work/Projekty/Harmony
git add elixir/assets/tsconfig.app.json \
        elixir/assets/src/types/contract.ts \
        elixir/assets/src/types/contract.test.ts \
        elixir/assets/src/test/fixtures/state_payload.fixture.json
git commit -m "test(frontend): cover state payload contract fixture"
```

---

### Task 6: Add A Deterministic React Browser E2E Harness

**Files:**
- Create: `elixir/lib/mix/tasks/harmony.react_spa_e2e_server.ex`
- Create: `elixir/assets/playwright.config.ts`
- Create: `elixir/assets/e2e/react-spa.spec.ts`
- Modify: `elixir/assets/package.json`
- Modify: `elixir/assets/package-lock.json`
- Modify: `elixir/Makefile`

- [ ] **Step 1: Install Playwright as a frontend dev dependency**

Run from `elixir/assets/`:

```bash
npm install -D @playwright/test
```

Expected: `package.json` and `package-lock.json` include `@playwright/test`.

- [ ] **Step 2: Add Playwright scripts**

In `elixir/assets/package.json`, add these scripts:

```json
"e2e": "playwright test",
"e2e:install": "playwright install chromium"
```

Keep the existing `dev`, `build`, `lint`, `test`, `typecheck`, and `preview` scripts.

- [ ] **Step 3: Create the deterministic Phoenix E2E server task**

Create `elixir/lib/mix/tasks/harmony.react_spa_e2e_server.ex`:

```elixir
defmodule Mix.Tasks.Harmony.ReactSpaE2eServer do
  @moduledoc """
  Starts a deterministic Phoenix server for the React SPA browser E2E harness.
  """

  use Mix.Task

  alias SymphonyElixir.HttpServer
  @shortdoc "Starts deterministic React SPA E2E server"
  @default_port 4201

  @impl Mix.Task
  def run(args) do
    {opts, _argv, invalid} = OptionParser.parse(args, strict: [port: :integer])

    if invalid != [] do
      Mix.raise("Invalid options: #{inspect(invalid)}")
    end

    port = Keyword.get(opts, :port, @default_port)
    Mix.Task.run("app.start")

    orchestrator = Module.concat(__MODULE__, Orchestrator)
    {:ok, _pid} = SnapshotOrchestrator.start_link(name: orchestrator)

    endpoint_config =
      :symphony_elixir
      |> Application.get_env(SymphonyElixirWeb.Endpoint, [])
      |> Keyword.merge(orchestrator: orchestrator, snapshot_timeout_ms: 100)

    Application.put_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, endpoint_config)

    case HttpServer.start_link(port: port, host: "127.0.0.1") do
      {:ok, _pid} ->
        Mix.shell().info("react_spa_e2e_server=http://127.0.0.1:#{port}")
        Process.sleep(:infinity)

      {:error, {:already_started, _pid}} ->
        Mix.shell().info("react_spa_e2e_server=http://127.0.0.1:#{port}")
        Process.sleep(:infinity)

      {:error, reason} ->
        Mix.raise("failed to start React SPA E2E server: #{inspect(reason)}")
    end
  end

  defmodule SnapshotOrchestrator do
    use GenServer

    def start_link(opts), do: GenServer.start_link(__MODULE__, 1, name: Keyword.fetch!(opts, :name))

    @impl true
    def init(version), do: {:ok, version}

    @impl true
    def handle_call(:snapshot, _from, version) do
      {:reply, snapshot(version), version}
    end

    def handle_call(:request_refresh, _from, version) do
      next_version = version + 1
      Process.send_after(self(), :broadcast_update, 0)
      {:reply, %{requested_at: DateTime.utc_now()}, next_version}
    end

    @impl true
    def handle_info(:broadcast_update, version) do
      :ok = SymphonyElixirWeb.ObservabilityPubSub.broadcast_update()
      {:noreply, version}
    end

    defp snapshot(version) do
      %{
        running: [
          %{
            issue_id: "issue-#{version}",
            identifier: "COD-#{version}",
            state: "In Progress",
            worker_host: nil,
            workspace_path: "/tmp/harmony-e2e/COD-#{version}",
            session_id: "session-#{version}",
            turn_count: version,
            last_codex_event: "turn.completed",
            last_codex_message: "E2E version #{version}",
            started_at: DateTime.add(DateTime.utc_now(), -60, :second),
            last_codex_timestamp: DateTime.utc_now(),
            codex_input_tokens: 10,
            codex_output_tokens: 20,
            codex_total_tokens: 30,
            project_id: "project-e2e",
            project_name: "React E2E",
            project_slug: "react-e2e"
          }
        ],
        retrying: [],
        blocked: [],
        runtime: %{
          sandbox: %{
            posture: "workspace_sandbox_requested",
            bubblewrap_available: true,
            apparmor_restrict_unprivileged_userns: 1,
            thread_sandbox: "workspace-write",
            turn_sandbox_type: "workspaceWrite",
            warnings: []
          }
        },
        artifacts: [
          %{kind: "screenshot", path: ".harmony/artifacts/react-e2e-#{version}.png"}
        ],
        codex_totals: %{input_tokens: 10, output_tokens: 20, total_tokens: 30, seconds_running: 60},
        rate_limits: %{remaining: 42}
      }
    end
  end
end
```

- [ ] **Step 4: Add Playwright config**

Create `elixir/assets/playwright.config.ts`:

```ts
import { defineConfig, devices } from "@playwright/test";

const port = Number(process.env.HARMONY_E2E_PORT ?? 4201);

export default defineConfig({
  testDir: "./e2e",
  timeout: 30_000,
  expect: { timeout: 10_000 },
  use: {
    baseURL: `http://127.0.0.1:${port}`,
    trace: "retain-on-failure",
    screenshot: "only-on-failure",
  },
  projects: [
    {
      name: "chromium",
      use: { ...devices["Desktop Chrome"] },
    },
  ],
  webServer: {
    command: `cd .. && mix assets.build && mix harmony.react_spa_e2e_server --port ${port}`,
    url: `http://127.0.0.1:${port}`,
    reuseExistingServer: !process.env.CI,
    timeout: 60_000,
  },
});
```

- [ ] **Step 5: Add the React SPA browser spec**

Create `elixir/assets/e2e/react-spa.spec.ts`:

```ts
import { expect, test } from "@playwright/test";

test("dashboard renders React data from REST and channel", async ({ page }) => {
  await page.goto("/");

  await expect(page.getByRole("heading", { name: "Dashboard" })).toBeVisible();
  await expect(page.getByText("COD-1")).toBeVisible();
  await expect(page.getByText(".harmony/artifacts/react-e2e-1.png")).toBeVisible();
  await expect(page.getByText("Live")).toBeVisible();

  await page.request.post("/api/v1/refresh");
  await expect(page.getByText("COD-2")).toBeVisible();
  await expect(page.getByText(".harmony/artifacts/react-e2e-2.png")).toBeVisible();
});

test("projects route is owned by the React router", async ({ page }) => {
  await page.goto("/projects");

  await expect(page.getByRole("heading", { name: "Projects" })).toBeVisible();
  await expect(page.getByRole("link", { name: "New project" })).toBeVisible();
});
```

- [ ] **Step 6: Update Makefile targets**

In `elixir/Makefile`, replace:

```make
e2e:
	SYMPHONY_RUN_LIVE_E2E=1 $(MIX) test test/symphony_elixir/live_e2e_test.exs
```

with:

```make
e2e:
	cd assets && npm run e2e

live-e2e:
	SYMPHONY_RUN_LIVE_E2E=1 $(MIX) test test/symphony_elixir/live_e2e_test.exs
```

Also update the `.PHONY` line:

```make
.PHONY: help all setup deps build assets fmt fmt-check lint test coverage ci dialyzer e2e live-e2e
```

And update the help output:

```make
	@echo "Targets: setup, deps, fmt, fmt-check, lint, test, coverage, dialyzer, e2e, live-e2e, ci"
```

- [ ] **Step 7: Install Chromium if needed**

Run from `elixir/assets/`:

```bash
npm run e2e:install
```

Expected: Playwright installs Chromium. If Chromium is already installed, Playwright exits 0 without changing source files.

- [ ] **Step 8: Verify the React browser E2E**

Run from `elixir/`:

```bash
make e2e
```

Expected: Playwright starts the deterministic Phoenix server, opens `/`, verifies the React dashboard, posts `/api/v1/refresh`, observes the channel update, opens `/projects`, and exits 0.

- [ ] **Step 9: Verify the old live E2E target remains available**

Run from `elixir/`:

```bash
make -n live-e2e
```

Expected output includes:

```text
SYMPHONY_RUN_LIVE_E2E=1 mix test test/symphony_elixir/live_e2e_test.exs
```

- [ ] **Step 10: Commit**

```bash
cd /work/Projekty/Harmony
git add elixir/Makefile \
        elixir/lib/mix/tasks/harmony.react_spa_e2e_server.ex \
        elixir/assets/package.json \
        elixir/assets/package-lock.json \
        elixir/assets/playwright.config.ts \
        elixir/assets/e2e/react-spa.spec.ts
git commit -m "test(e2e): drive React SPA in browser harness"
```

---

### Task 7: Fix Stale Phase 0 Documentation Text

**Files:**
- Modify: `elixir/assets/CLAUDE.md`
- Modify: `elixir/assets/AGENTS.md`
- Modify: `elixir/lib/symphony_elixir_web/controllers/spa_controller.ex`

- [ ] **Step 1: Update the SPA controller moduledoc**

In `elixir/lib/symphony_elixir_web/controllers/spa_controller.ex`, replace:

```elixir
  Serves the React SPA's index.html for client-side routes under /app.
```

with:

```elixir
  Serves the React SPA's index.html for client-side routes at the root path.
```

- [ ] **Step 2: Update frontend run docs**

In `elixir/assets/CLAUDE.md`, replace the current `## Run` and `## Routing note` sections with:

```markdown
## Run

- **Dev:** start Phoenix (the OTP app boots the server), then `npm run dev` here. Vite proxies
  `/api` and `/socket` to Phoenix on `http://localhost:${HARMONY_PORT:-4000}`. Open
  http://localhost:5173/. If Phoenix runs on another port, use `HARMONY_PORT=<port> npm run dev`.
- **Tests:** `npm run test -- --run`
- **Typecheck:** `npm run typecheck`
- **Build:** from `elixir/`, `mix assets.build` (or `npm run build` here).
- **Browser E2E:** from `elixir/`, `make e2e` runs the deterministic React SPA Playwright harness.

## Routing note

The Phase 3 cutover is complete: Vite builds with `base: "/"`, Phoenix serves `priv/static/app`
from `/`, and React Router owns `/`, `/projects`, `/projects/new`, and `/projects/:id/edit`.
```

In `elixir/assets/AGENTS.md`, replace the final bullet:

```markdown
- Alias `@/*` → `src/*`. Tests: Vitest + RTL (`npm run test -- --run`). Build: `mix assets.build`
  from `elixir/`.
```

with:

```markdown
- Alias `@/*` → `src/*`. Tests: Vitest + RTL (`npm run test -- --run`). Browser E2E:
  `make e2e` from `elixir/`. Build: `mix assets.build` from `elixir/`.
```

- [ ] **Step 3: Verify no stale `/app` dev URL remains**

Run from repo root:

```bash
rg -n "localhost:5173/app|under /app|base: \"\\/app\\/\"" elixir/assets elixir/lib/symphony_elixir_web/controllers/spa_controller.ex
```

Expected: no matches.

- [ ] **Step 4: Verify Elixir formatting**

Run from `elixir/`:

```bash
mix format --check-formatted
```

Expected: exits 0.

- [ ] **Step 5: Commit**

```bash
cd /work/Projekty/Harmony
git add elixir/assets/CLAUDE.md \
        elixir/assets/AGENTS.md \
        elixir/lib/symphony_elixir_web/controllers/spa_controller.ex
git commit -m "docs(frontend): describe root-served React SPA"
```

---

### Task 8: Final Validation And PR Body Refresh

**Files:**
- Modify: PR body for the current branch using `gh pr edit`

- [ ] **Step 1: Run the full backend gate**

Run from repo root:

```bash
mise exec --cd elixir -- make all
```

Expected: assets build succeeds, `mix format --check-formatted` exits 0, `mix lint` exits 0, `mix test --cover` reports `336 tests, 0 failures, 2 skipped` or the updated count with `0 failures`, and Dialyzer reports `Total errors: 0`.

- [ ] **Step 2: Run the full frontend gate**

Run from `elixir/assets/`:

```bash
npm run lint && npm run test -- --run && npm run build
```

Expected: all three commands exit 0.

- [ ] **Step 3: Run the React browser E2E**

Run from `elixir/`:

```bash
make e2e
```

Expected: Playwright exits 0 and verifies `/`, `/projects`, and a refresh-driven dashboard update.

- [ ] **Step 4: Verify no LiveView runtime dependency or UI route returned**

Run from repo root:

```bash
rg -n "phoenix_live_view|Phoenix.LiveView|DashboardLive|ProjectsLive|ProjectFormLive|StaticAssetController|dashboard.css|/vendor/|socket\\(\"/live\"" elixir/lib elixir/test elixir/mix.exs elixir/mix.lock
```

Expected: no matches.

- [ ] **Step 5: Refresh the PR body**

Create `/tmp/react-migration-pr-body.md` with:

```markdown
#### Context

The Phoenix UI is moving from LiveView pages to a React SPA hydrated by REST and Phoenix Channels.

#### TL;DR

*Completes the React SPA cutover and closes the review gaps.*

#### Summary

- Serve the React SPA at `/` with LiveView and legacy static assets removed
- Add REST project CRUD, channel-backed dashboard hydration, and durable/runtime artifact rendering
- Add connection-state UI, contract fixture coverage, and deterministic React browser E2E
- Refresh frontend docs for the root-served SPA workflow

#### Alternatives

- Keeping only ExUnit SPA shell tests was rejected because the spec requires browser proof for React.

#### Test Plan

- [x] `mise exec --cd elixir -- make all`
- [x] `npm run lint && npm run test -- --run && npm run build`
- [x] `make e2e`
```

Then run:

```bash
mise exec --cd elixir -- mix pr_body.check --file /tmp/react-migration-pr-body.md
gh pr edit --body-file /tmp/react-migration-pr-body.md
rm -f /tmp/react-migration-pr-body.md
```

Expected: `mix pr_body.check` prints `PR body format OK`, and `gh pr edit` exits 0.

- [ ] **Step 6: Final status check**

Run from repo root:

```bash
git status -sb
gh pr view --json url,title,isDraft,headRefName,baseRefName
```

Expected: working tree clean except for the branch tracking line, PR remains open/draft unless the user explicitly asks to mark it ready.

---

## Self-Review

- Spec coverage: the plan covers final frontend gate, runtime artifact visibility, WebSocket reconnect/offline status, `422.fields` mapping, durable TypeScript contract coverage, React browser E2E, and stale docs.
- Placeholder scan: no task uses placeholder language; every code-changing step includes concrete code or exact command output expectations.
- Type consistency: `DashboardConnectionStatus`, `StatePayload`, durable interfaces, `EvidenceArtifact`, and `ProjectFormValues` names are defined before later tasks use them.

## Execution Handoff

Plan complete and saved to `docs/superpowers/plans/2026-06-02-react-migration-review-fixes.md`. Two execution options:

**1. Subagent-Driven (recommended)** - dispatch a fresh subagent per task, review between tasks, fast iteration.

**2. Inline Execution** - execute tasks in this session using executing-plans, batch execution with checkpoints.
