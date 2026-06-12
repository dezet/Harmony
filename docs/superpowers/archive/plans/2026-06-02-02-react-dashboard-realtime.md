# Phase 1 — Real-Time Dashboard Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Deliver the observability dashboard as a React screen that loads initial state over REST and receives live updates over a Phoenix Channel that pushes `Presenter.state_payload/0` into the React Query cache.

**Architecture:** Add a `UserSocket` at `/socket` and an `ObservabilityChannel` on topic `"observability:dashboard"`. On join the channel replies with the current `state_payload`; on the existing `:observability_updated` PubSub message it pushes a fresh `state_payload` as a `"state"` event. The React client opens the channel once (in a provider), writes every snapshot into the React Query cache under `['dashboard']`, and renders slices via selectors. Elapsed/countdown values are computed client-side with a local `useNow()` tick. The Channel and `GET /api/v1/state` reuse the exact same Presenter — one serialization path.

**Tech Stack:** Phoenix.Socket/Channel, ExUnit (`Phoenix.ChannelTest`); TypeScript, React Query, the `phoenix` JS client, Vitest + RTL.

**Prereq:** Phase 0 complete (SPA served under `/app`, Vitest harness, shadcn).

---

## File Structure

Backend:
- Create: `elixir/lib/symphony_elixir_web/channels/user_socket.ex`
- Create: `elixir/lib/symphony_elixir_web/channels/observability_channel.ex`
- Modify: `elixir/lib/symphony_elixir_web/endpoint.ex` (mount `/socket`)
- Create: `elixir/test/symphony_elixir/observability_channel_test.exs`

Frontend (`elixir/assets/src/`):
- Create: `types/contract.ts` — wire-contract types.
- Create: `lib/api.ts` — typed REST client + `ApiError`.
- Create: `lib/queryClient.ts` — the React Query client.
- Create: `lib/socket.ts` — Phoenix socket + `useDashboardChannel` hook.
- Create: `lib/useNow.ts` — local 1s clock.
- Create: `lib/format.ts` — duration/number formatters.
- Create: `providers/AppProviders.tsx` — QueryClientProvider + channel.
- Create: `features/dashboard/useDashboard.ts` — selectors over `['dashboard']`.
- Create: `features/dashboard/components/*` — Metric cards, sessions tables, connection indicator.
- Modify: `routes/DashboardPage.tsx`, `main.tsx`.

---

### Task 1: UserSocket + ObservabilityChannel

**Files:**
- Create: `elixir/lib/symphony_elixir_web/channels/user_socket.ex`
- Create: `elixir/lib/symphony_elixir_web/channels/observability_channel.ex`
- Modify: `elixir/lib/symphony_elixir_web/endpoint.ex`
- Test: `elixir/test/symphony_elixir/observability_channel_test.exs`

- [ ] **Step 1: Write the failing channel test**

`elixir/test/symphony_elixir/observability_channel_test.exs`:

```elixir
defmodule SymphonyElixir.ObservabilityChannelTest do
  use SymphonyElixir.TestSupport

  import Phoenix.ChannelTest
  import Phoenix.ConnTest

  @endpoint SymphonyElixirWeb.Endpoint

  defmodule FakeOrchestrator do
    use GenServer

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: Keyword.fetch!(opts, :name))

    @impl true
    def init(_opts), do: {:ok, %{}}

    @impl true
    def handle_call(:snapshot, _from, state) do
      snapshot = %{
        running: [],
        retrying: [],
        blocked: [],
        runtime: %{},
        artifacts: [],
        codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
        rate_limits: %{},
        projects: []
      }

      {:reply, snapshot, state}
    end
  end

  setup do
    orchestrator_name = Module.concat(__MODULE__, :Orchestrator)
    start_supervised!({FakeOrchestrator, name: orchestrator_name})
    start_test_endpoint(orchestrator_name)
    :ok
  end

  test "join replies with the current state payload" do
    {:ok, reply, _socket} = join_dashboard()

    assert %{state: %{generated_at: _, counts: %{running: 0, retrying: 0, blocked: 0}}} = reply
  end

  test "pushes a fresh state payload when observability updates" do
    {:ok, _reply, _socket} = join_dashboard()

    :ok = SymphonyElixirWeb.ObservabilityPubSub.broadcast_update()

    assert_push("state", %{generated_at: _, counts: %{running: 0}})
  end

  test "channel join state matches GET /api/v1/state (single serialization path)" do
    {:ok, %{state: channel_state}, _socket} = join_dashboard()

    api_state = json_response(get(build_conn(), "/api/v1/state"), 200)

    # generated_at is stamped per call; everything else must be identical.
    # (channel_state has atom keys, the API response has string keys after JSON.)
    assert stringify(Map.delete(channel_state, :generated_at)) ==
             Map.delete(api_state, "generated_at")
  end

  defp stringify(term), do: term |> Jason.encode!() |> Jason.decode!()

  defp join_dashboard do
    SymphonyElixirWeb.UserSocket
    |> socket("user_socket", %{})
    |> subscribe_and_join(SymphonyElixirWeb.ObservabilityChannel, "observability:dashboard")
  end

  defp start_test_endpoint(orchestrator_name) do
    endpoint_config =
      :symphony_elixir
      |> Application.get_env(SymphonyElixirWeb.Endpoint, [])
      |> Keyword.merge(
        server: false,
        secret_key_base: String.duplicate("s", 64),
        orchestrator: orchestrator_name
      )

    Application.put_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, endpoint_config)
    start_supervised!({SymphonyElixirWeb.Endpoint, []})
  end
end
```

- [ ] **Step 2: Run it to verify it fails**

```bash
cd /work/Projekty/Harmony/elixir
mix test test/symphony_elixir/observability_channel_test.exs
```

Expected: FAIL — `SymphonyElixirWeb.UserSocket` / `ObservabilityChannel` are undefined.

- [ ] **Step 3: Create the UserSocket**

`elixir/lib/symphony_elixir_web/channels/user_socket.ex`:

```elixir
defmodule SymphonyElixirWeb.UserSocket do
  @moduledoc """
  Socket for the React client. Carries the observability channel.

  Auth seam: `connect/3` currently accepts all connections (trusted environment,
  matching the API and `check_origin: false`). Token validation attaches here later.
  """

  use Phoenix.Socket

  channel("observability:dashboard", SymphonyElixirWeb.ObservabilityChannel)

  @impl true
  def connect(_params, socket, _connect_info), do: {:ok, socket}

  @impl true
  def id(_socket), do: nil
end
```

- [ ] **Step 4: Create the ObservabilityChannel**

`elixir/lib/symphony_elixir_web/channels/observability_channel.ex`:

```elixir
defmodule SymphonyElixirWeb.ObservabilityChannel do
  @moduledoc """
  Pushes the observability `state_payload` to React clients: once on join, then on
  every `:observability_updated` PubSub broadcast. Reuses `Presenter.state_payload/0`
  so the wire shape is identical to `GET /api/v1/state`.
  """

  use Phoenix.Channel

  alias SymphonyElixirWeb.{Endpoint, ObservabilityPubSub, Presenter}

  @impl true
  def join("observability:dashboard", _payload, socket) do
    :ok = ObservabilityPubSub.subscribe()
    {:ok, %{state: state_payload()}, socket}
  end

  @impl true
  def handle_info(:observability_updated, socket) do
    push(socket, "state", state_payload())
    {:noreply, socket}
  end

  defp state_payload, do: Presenter.state_payload(orchestrator(), snapshot_timeout_ms())

  defp orchestrator, do: Endpoint.config(:orchestrator) || SymphonyElixir.Orchestrator

  defp snapshot_timeout_ms, do: Endpoint.config(:snapshot_timeout_ms) || 15_000
end
```

- [ ] **Step 5: Mount the socket in the endpoint**

In `elixir/lib/symphony_elixir_web/endpoint.ex`, add after the existing `socket("/live", ...)` call:

```elixir
  socket("/socket", SymphonyElixirWeb.UserSocket,
    websocket: [connect_info: [session: @session_options]],
    longpoll: false
  )
```

- [ ] **Step 6: Run the test to verify it passes**

```bash
cd /work/Projekty/Harmony/elixir
mix test test/symphony_elixir/observability_channel_test.exs
```

Expected: 2 passing tests.

- [ ] **Step 7: Format, full test, commit**

```bash
cd /work/Projekty/Harmony/elixir
mix format
mix test
cd /work/Projekty/Harmony
git add elixir/lib/symphony_elixir_web/channels elixir/lib/symphony_elixir_web/endpoint.ex elixir/test/symphony_elixir/observability_channel_test.exs
git commit -m "feat(web): add observability channel that pushes state_payload"
```

---

### Task 2: Wire-contract TypeScript types

**Files:**
- Create: `elixir/assets/src/types/contract.ts`

These mirror `SymphonyElixirWeb.Presenter`. Optional keys use `?` because the Presenter omits `projects`/`durable` when empty and returns `{generated_at, error}` on snapshot failure.

- [ ] **Step 1: Create `src/types/contract.ts`**

```ts
export interface ProjectRef {
  id: string | null;
  name: string | null;
  slug: string | null;
}

export interface Tokens {
  input_tokens: number;
  output_tokens: number;
  total_tokens: number;
}

export interface RunningEntry {
  issue_id: string;
  issue_identifier: string;
  state: string;
  worker_host: string | null;
  workspace_path: string | null;
  session_id: string | null;
  turn_count: number;
  last_event: string | null;
  last_message: string | null;
  started_at: string | null;
  last_event_at: string | null;
  tokens: Tokens;
  project: ProjectRef | null;
}

export interface RetryEntry {
  issue_id: string;
  issue_identifier: string;
  attempt: number;
  due_at: string | null;
  error: string | null;
  worker_host: string | null;
  workspace_path: string | null;
  project: ProjectRef | null;
}

export interface BlockedEntry {
  issue_id: string;
  issue_identifier: string;
  state: string;
  error: string | null;
  worker_host: string | null;
  workspace_path: string | null;
  session_id: string | null;
  blocked_at: string | null;
  last_event: string | null;
  last_message: string | null;
  last_event_at: string | null;
  project: ProjectRef | null;
}

export interface CodexTotals {
  input_tokens: number;
  output_tokens: number;
  total_tokens: number;
  seconds_running: number;
}

export interface SandboxRuntime {
  posture: string | null;
  bubblewrap_available: boolean | null;
  apparmor_restrict_unprivileged_userns: number | null;
  thread_sandbox: string | null;
  turn_sandbox_type: string | null;
  warnings: string[];
}

export interface Runtime {
  sandbox?: SandboxRuntime;
}

export interface Artifact {
  kind?: string;
  path?: string;
  [key: string]: unknown;
}

export interface StateError {
  code: string;
  message: string;
}

export interface StatePayload {
  generated_at: string;
  counts?: { running: number; retrying: number; blocked: number };
  running?: RunningEntry[];
  retrying?: RetryEntry[];
  blocked?: BlockedEntry[];
  runtime?: Runtime;
  artifacts?: Artifact[];
  codex_totals?: CodexTotals;
  rate_limits?: unknown;
  projects?: Array<ProjectRef & { counts: { running: number; retrying: number; blocked: number } }>;
  durable?: Record<string, unknown>;
  error?: StateError;
}

export interface ApiErrorBody {
  error: { code: string; message: string; fields?: Record<string, string[]> };
}
```

- [ ] **Step 2: Commit**

```bash
cd /work/Projekty/Harmony
git add elixir/assets/src/types/contract.ts
git commit -m "feat(frontend): add wire-contract types mirroring Presenter"
```

---

### Task 3: REST client + ApiError

**Files:**
- Create: `elixir/assets/src/lib/api.ts`
- Create: `elixir/assets/src/lib/api.test.ts`

- [ ] **Step 1: Write the failing test**

`elixir/assets/src/lib/api.test.ts`:

```ts
import { describe, it, expect, vi, afterEach } from "vitest";
import { getState, ApiError } from "@/lib/api";

afterEach(() => vi.restoreAllMocks());

describe("api client", () => {
  it("getState returns parsed JSON", async () => {
    vi.stubGlobal(
      "fetch",
      vi.fn(async () =>
        new Response(JSON.stringify({ generated_at: "2026-06-02T00:00:00Z" }), {
          status: 200,
          headers: { "content-type": "application/json" },
        }),
      ),
    );

    const state = await getState();
    expect(state.generated_at).toBe("2026-06-02T00:00:00Z");
  });

  it("throws ApiError with code on error envelope", async () => {
    vi.stubGlobal(
      "fetch",
      vi.fn(async () =>
        new Response(JSON.stringify({ error: { code: "not_found", message: "nope" } }), {
          status: 404,
          headers: { "content-type": "application/json" },
        }),
      ),
    );

    await expect(getState()).rejects.toMatchObject({ code: "not_found", status: 404 });
    await expect(getState()).rejects.toBeInstanceOf(ApiError);
  });
});
```

- [ ] **Step 2: Run it to verify it fails**

```bash
cd /work/Projekty/Harmony/assets 2>/dev/null || cd /work/Projekty/Harmony/elixir/assets
npm run test -- --run src/lib/api.test.ts
```

Expected: FAIL — `@/lib/api` missing.

- [ ] **Step 3: Implement `src/lib/api.ts`**

```ts
import type { ApiErrorBody, StatePayload } from "@/types/contract";

export class ApiError extends Error {
  code: string;
  status: number;
  fields?: Record<string, string[]>;

  constructor(status: number, code: string, message: string, fields?: Record<string, string[]>) {
    super(message);
    this.name = "ApiError";
    this.status = status;
    this.code = code;
    this.fields = fields;
  }
}

const BASE = "/api/v1";

async function request<T>(path: string, init?: RequestInit): Promise<T> {
  const res = await fetch(`${BASE}${path}`, {
    headers: { "content-type": "application/json", ...(init?.headers ?? {}) },
    ...init,
  });

  const text = await res.text();
  const data = text ? JSON.parse(text) : null;

  if (!res.ok) {
    const body = data as ApiErrorBody | null;
    const err = body?.error;
    throw new ApiError(
      res.status,
      err?.code ?? "http_error",
      err?.message ?? `Request failed with ${res.status}`,
      err?.fields,
    );
  }

  return data as T;
}

export function getState(): Promise<StatePayload> {
  return request<StatePayload>("/state");
}

export function requestRefresh(): Promise<unknown> {
  return request<unknown>("/refresh", { method: "POST" });
}
```

- [ ] **Step 4: Run the test to verify it passes**

```bash
npm run test -- --run src/lib/api.test.ts
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
cd /work/Projekty/Harmony
git add elixir/assets/src/lib/api.ts elixir/assets/src/lib/api.test.ts
git commit -m "feat(frontend): add typed REST client with ApiError"
```

---

### Task 4: Query client + Channel hydration hook

**Files:**
- Create: `elixir/assets/src/lib/queryClient.ts`
- Create: `elixir/assets/src/lib/socket.ts`
- Create: `elixir/assets/src/lib/socket.test.ts`

- [ ] **Step 1: Create the query client + key**

`elixir/assets/src/lib/queryClient.ts`:

```ts
import { QueryClient } from "@tanstack/react-query";

export const queryClient = new QueryClient({
  defaultOptions: { queries: { retry: 1, refetchOnWindowFocus: false } },
});

export const DASHBOARD_KEY = ["dashboard"] as const;
```

- [ ] **Step 2: Write a failing test for the hydration logic**

`elixir/assets/src/lib/socket.test.ts`:

```ts
import { describe, it, expect, vi } from "vitest";
import { QueryClient } from "@tanstack/react-query";
import { hydrateFromChannel, DASHBOARD_KEY } from "@/lib/socket";

describe("channel hydration", () => {
  it("writes join state and pushed state into the query cache", () => {
    const qc = new QueryClient();

    // Fake phoenix channel: records the join handler and "state" handler.
    const handlers: Record<string, (payload: unknown) => void> = {};
    const channel = {
      on: (event: string, cb: (payload: unknown) => void) => {
        handlers[event] = cb;
        return 0;
      },
      join: () => ({
        receive(status: string, cb: (resp: unknown) => void) {
          if (status === "ok") cb({ state: { generated_at: "join" } });
          return this;
        },
      }),
    };

    hydrateFromChannel(qc, channel as never);
    expect(qc.getQueryData(DASHBOARD_KEY)).toEqual({ generated_at: "join" });

    handlers["state"]({ generated_at: "push" });
    expect(qc.getQueryData(DASHBOARD_KEY)).toEqual({ generated_at: "push" });
  });
});
```

- [ ] **Step 3: Run it to verify it fails**

```bash
npm run test -- --run src/lib/socket.test.ts
```

Expected: FAIL — `@/lib/socket` missing.

- [ ] **Step 4: Implement `src/lib/socket.ts`**

```ts
import { Socket, type Channel } from "phoenix";
import type { QueryClient } from "@tanstack/react-query";
import { useEffect } from "react";
import type { StatePayload } from "@/types/contract";
import { DASHBOARD_KEY } from "@/lib/queryClient";

export { DASHBOARD_KEY };

function csrfToken(): string | undefined {
  return document.querySelector("meta[name='csrf-token']")?.getAttribute("content") ?? undefined;
}

export function createSocket(): Socket {
  const socket = new Socket("/socket", { params: { token: csrfToken() } });
  socket.connect();
  return socket;
}

/**
 * Subscribe a phoenix channel to the dashboard topic and write every snapshot
 * (the join reply and each "state" push) into the React Query cache.
 * Returns a cleanup function that leaves the channel.
 */
export function hydrateFromChannel(queryClient: QueryClient, channel: Channel): () => void {
  channel.on("state", (payload: StatePayload) => {
    queryClient.setQueryData(DASHBOARD_KEY, payload);
  });

  channel
    .join()
    .receive("ok", (resp: { state: StatePayload }) => {
      queryClient.setQueryData(DASHBOARD_KEY, resp.state);
    });

  return () => {
    channel.leave();
  };
}

/** Open the dashboard channel for the lifetime of the component tree. */
export function useDashboardChannel(queryClient: QueryClient): void {
  useEffect(() => {
    const socket = createSocket();
    const channel = socket.channel("observability:dashboard", {});
    const cleanup = hydrateFromChannel(queryClient, channel);
    return () => {
      cleanup();
      socket.disconnect();
    };
  }, [queryClient]);
}
```

- [ ] **Step 5: Run the test to verify it passes**

```bash
npm run test -- --run src/lib/socket.test.ts
```

Expected: PASS.

- [ ] **Step 6: Commit**

```bash
cd /work/Projekty/Harmony
git add elixir/assets/src/lib/queryClient.ts elixir/assets/src/lib/socket.ts elixir/assets/src/lib/socket.test.ts
git commit -m "feat(frontend): hydrate React Query cache from the dashboard channel"
```

---

### Task 5: useNow clock + formatters

**Files:**
- Create: `elixir/assets/src/lib/useNow.ts`
- Create: `elixir/assets/src/lib/format.ts`
- Create: `elixir/assets/src/lib/format.test.ts`

- [ ] **Step 1: Write failing formatter tests**

`elixir/assets/src/lib/format.test.ts`:

```ts
import { describe, it, expect } from "vitest";
import { formatDuration, elapsedSeconds } from "@/lib/format";

describe("format", () => {
  it("formats seconds as H:MM:SS-ish text", () => {
    expect(formatDuration(0)).toBe("0s");
    expect(formatDuration(65)).toBe("1m 5s");
    expect(formatDuration(3661)).toBe("1h 1m 1s");
  });

  it("computes elapsed seconds from an ISO timestamp", () => {
    const now = new Date("2026-06-02T00:01:00Z").getTime();
    expect(elapsedSeconds("2026-06-02T00:00:00Z", now)).toBe(60);
    expect(elapsedSeconds(null, now)).toBeNull();
  });
});
```

- [ ] **Step 2: Run it to verify it fails**

```bash
npm run test -- --run src/lib/format.test.ts
```

Expected: FAIL — `@/lib/format` missing.

- [ ] **Step 3: Implement the formatters**

`elixir/assets/src/lib/format.ts`:

```ts
export function elapsedSeconds(iso: string | null, nowMs: number): number | null {
  if (!iso) return null;
  return Math.max(0, Math.floor((nowMs - new Date(iso).getTime()) / 1000));
}

export function formatDuration(totalSeconds: number): string {
  if (totalSeconds <= 0) return "0s";
  const h = Math.floor(totalSeconds / 3600);
  const m = Math.floor((totalSeconds % 3600) / 60);
  const s = totalSeconds % 60;
  return [h ? `${h}h` : null, h || m ? `${m}m` : null, `${s}s`].filter(Boolean).join(" ");
}
```

- [ ] **Step 4: Implement the clock hook**

`elixir/assets/src/lib/useNow.ts`:

```ts
import { useEffect, useState } from "react";

/** Returns the current epoch-ms, re-rendering every `intervalMs` (default 1s). */
export function useNow(intervalMs = 1000): number {
  const [now, setNow] = useState(() => Date.now());
  useEffect(() => {
    const id = setInterval(() => setNow(Date.now()), intervalMs);
    return () => clearInterval(id);
  }, [intervalMs]);
  return now;
}
```

- [ ] **Step 5: Run tests to verify they pass**

```bash
npm run test -- --run src/lib/format.test.ts
```

Expected: PASS.

- [ ] **Step 6: Commit**

```bash
cd /work/Projekty/Harmony
git add elixir/assets/src/lib/useNow.ts elixir/assets/src/lib/format.ts elixir/assets/src/lib/format.test.ts
git commit -m "feat(frontend): add useNow clock and duration formatters"
```

---

### Task 6: App providers (QueryClient + channel) and dashboard query hook

**Files:**
- Create: `elixir/assets/src/providers/AppProviders.tsx`
- Create: `elixir/assets/src/features/dashboard/useDashboard.ts`
- Modify: `elixir/assets/src/main.tsx`

- [ ] **Step 1a: Create a React error boundary**

`elixir/assets/src/components/ErrorBoundary.tsx`:

```tsx
import { Component, type ReactNode } from "react";

interface Props {
  children: ReactNode;
}
interface State {
  error: Error | null;
}

// React requires a class component for error boundaries.
export class ErrorBoundary extends Component<Props, State> {
  state: State = { error: null };

  static getDerivedStateFromError(error: Error): State {
    return { error };
  }

  render() {
    if (this.state.error) {
      return (
        <div className="p-6">
          <h1 className="text-xl font-semibold text-destructive">Something went wrong</h1>
          <pre className="mt-2 text-sm">{this.state.error.message}</pre>
        </div>
      );
    }
    return this.props.children;
  }
}
```

- [ ] **Step 1b: Create the providers**

`elixir/assets/src/providers/AppProviders.tsx`:

```tsx
import { QueryClientProvider } from "@tanstack/react-query";
import type { ReactNode } from "react";
import { queryClient } from "@/lib/queryClient";
import { useDashboardChannel } from "@/lib/socket";
import { ErrorBoundary } from "@/components/ErrorBoundary";

function ChannelBridge({ children }: { children: ReactNode }) {
  useDashboardChannel(queryClient);
  return <>{children}</>;
}

export function AppProviders({ children }: { children: ReactNode }) {
  return (
    <ErrorBoundary>
      <QueryClientProvider client={queryClient}>
        <ChannelBridge>{children}</ChannelBridge>
      </QueryClientProvider>
    </ErrorBoundary>
  );
}
```

- [ ] **Step 2: Create the dashboard query hook**

`elixir/assets/src/features/dashboard/useDashboard.ts`:

```ts
import { useQuery } from "@tanstack/react-query";
import { getState } from "@/lib/api";
import { DASHBOARD_KEY } from "@/lib/queryClient";
import type { StatePayload } from "@/types/contract";

// Initial load + reconnect come from REST; live updates arrive via the channel
// (which writes the same cache key). staleTime Infinity = never auto-refetch.
export function useDashboard() {
  return useQuery<StatePayload>({
    queryKey: DASHBOARD_KEY,
    queryFn: getState,
    staleTime: Infinity,
  });
}
```

- [ ] **Step 3: Wrap the app with providers in `main.tsx`**

Edit `elixir/assets/src/main.tsx` to wrap `<AppRoutes />` with `<AppProviders>`:

```tsx
import React from "react";
import ReactDOM from "react-dom/client";
import { BrowserRouter } from "react-router-dom";
import { AppRoutes } from "@/App";
import { AppProviders } from "@/providers/AppProviders";
import "./index.css";

const basename = import.meta.env.BASE_URL.replace(/\/$/, "");

ReactDOM.createRoot(document.getElementById("root")!).render(
  <React.StrictMode>
    <AppProviders>
      <BrowserRouter basename={basename}>
        <AppRoutes />
      </BrowserRouter>
    </AppProviders>
  </React.StrictMode>,
);
```

- [ ] **Step 4: Verify build + existing tests still pass**

```bash
cd /work/Projekty/Harmony/elixir/assets
npm run test -- --run && npm run build
```

Expected: all green; build exits 0.

- [ ] **Step 5: Commit**

```bash
cd /work/Projekty/Harmony
git add elixir/assets/src/providers elixir/assets/src/features/dashboard/useDashboard.ts elixir/assets/src/main.tsx
git commit -m "feat(frontend): wire QueryClient + dashboard channel providers"
```

---

### Task 7: Dashboard metric cards + connection indicator

**Files:**
- Create: `elixir/assets/src/features/dashboard/components/MetricCards.tsx`
- Create: `elixir/assets/src/features/dashboard/components/MetricCards.test.tsx`
- Create: `elixir/assets/src/features/dashboard/components/ConnectionStatus.tsx`
- Add shadcn `card` and `badge` primitives.

- [ ] **Step 1: Add shadcn primitives**

```bash
cd /work/Projekty/Harmony/elixir/assets
npx shadcn@latest add card badge table skeleton alert
```

Expected: creates `src/components/ui/{card,badge,table,skeleton,alert}.tsx`.

- [ ] **Step 2: Write a failing MetricCards test**

`elixir/assets/src/features/dashboard/components/MetricCards.test.tsx`:

```tsx
import { render, screen } from "@testing-library/react";
import { describe, it, expect } from "vitest";
import { MetricCards } from "@/features/dashboard/components/MetricCards";
import type { StatePayload } from "@/types/contract";

const state: StatePayload = {
  generated_at: "2026-06-02T00:00:00Z",
  counts: { running: 2, retrying: 1, blocked: 3 },
  codex_totals: { input_tokens: 10, output_tokens: 20, total_tokens: 30, seconds_running: 0 },
};

describe("MetricCards", () => {
  it("renders the running/retrying/blocked counts and token total", () => {
    render(<MetricCards state={state} />);
    expect(screen.getByText("Running").closest("div")).toHaveTextContent("2");
    expect(screen.getByText("Retrying").closest("div")).toHaveTextContent("1");
    expect(screen.getByText("Blocked").closest("div")).toHaveTextContent("3");
    expect(screen.getByText("Total tokens").closest("div")).toHaveTextContent("30");
  });
});
```

- [ ] **Step 3: Run it to verify it fails**

```bash
npm run test -- --run src/features/dashboard/components/MetricCards.test.tsx
```

Expected: FAIL — component missing.

- [ ] **Step 4: Implement MetricCards**

`elixir/assets/src/features/dashboard/components/MetricCards.tsx`:

```tsx
import { Card, CardHeader, CardTitle, CardContent } from "@/components/ui/card";
import type { StatePayload } from "@/types/contract";

function Metric({ label, value }: { label: string; value: number | string }) {
  return (
    <Card>
      <CardHeader>
        <CardTitle className="text-sm text-muted-foreground">{label}</CardTitle>
      </CardHeader>
      <CardContent className="text-3xl font-semibold">{value}</CardContent>
    </Card>
  );
}

export function MetricCards({ state }: { state: StatePayload }) {
  const counts = state.counts ?? { running: 0, retrying: 0, blocked: 0 };
  const totalTokens = state.codex_totals?.total_tokens ?? 0;

  return (
    <div className="grid grid-cols-2 md:grid-cols-4 gap-4">
      <Metric label="Running" value={counts.running} />
      <Metric label="Retrying" value={counts.retrying} />
      <Metric label="Blocked" value={counts.blocked} />
      <Metric label="Total tokens" value={totalTokens} />
    </div>
  );
}
```

- [ ] **Step 5: Implement the connection indicator**

`elixir/assets/src/features/dashboard/components/ConnectionStatus.tsx`:

```tsx
import { useIsFetching } from "@tanstack/react-query";
import { Badge } from "@/components/ui/badge";
import { DASHBOARD_KEY } from "@/lib/queryClient";

// "Live" once we have data; "Connecting…" while the first fetch/join is in flight.
export function ConnectionStatus({ hasData }: { hasData: boolean }) {
  const fetching = useIsFetching({ queryKey: DASHBOARD_KEY });
  if (hasData) return <Badge variant="secondary">Live</Badge>;
  return <Badge variant="outline">{fetching ? "Connecting…" : "Offline"}</Badge>;
}
```

- [ ] **Step 6: Run the test to verify it passes**

```bash
npm run test -- --run src/features/dashboard/components/MetricCards.test.tsx
```

Expected: PASS.

- [ ] **Step 7: Commit**

```bash
cd /work/Projekty/Harmony
git add elixir/assets/src/components/ui elixir/assets/src/features/dashboard/components
git commit -m "feat(frontend): dashboard metric cards and connection indicator"
```

---

### Task 8: Sessions tables (running / retrying / blocked) with live countdowns

**Files:**
- Create: `elixir/assets/src/features/dashboard/components/RunningTable.tsx`
- Create: `elixir/assets/src/features/dashboard/components/RetryTable.tsx`
- Create: `elixir/assets/src/features/dashboard/components/BlockedTable.tsx`
- Create: `elixir/assets/src/features/dashboard/components/RunningTable.test.tsx`

- [ ] **Step 1: Write a failing RunningTable test (live elapsed time)**

`elixir/assets/src/features/dashboard/components/RunningTable.test.tsx`:

```tsx
import { render, screen } from "@testing-library/react";
import { describe, it, expect } from "vitest";
import { RunningTable } from "@/features/dashboard/components/RunningTable";
import type { RunningEntry } from "@/types/contract";

const nowMs = new Date("2026-06-02T00:01:00Z").getTime();

const entry: RunningEntry = {
  issue_id: "1",
  issue_identifier: "COD-1",
  state: "running",
  worker_host: "host-a",
  workspace_path: null,
  session_id: "s1",
  turn_count: 3,
  last_event: "codex.message",
  last_message: "working",
  started_at: "2026-06-02T00:00:00Z",
  last_event_at: null,
  tokens: { input_tokens: 1, output_tokens: 2, total_tokens: 3 },
  project: { id: "p", name: "Portal", slug: "portal" },
};

describe("RunningTable", () => {
  it("renders a row with identifier, project, and elapsed time", () => {
    render(<RunningTable rows={[entry]} nowMs={nowMs} />);
    expect(screen.getByText("COD-1")).toBeInTheDocument();
    expect(screen.getByText("Portal")).toBeInTheDocument();
    expect(screen.getByText("1m 0s")).toBeInTheDocument();
  });

  it("renders an empty state when there are no rows", () => {
    render(<RunningTable rows={[]} nowMs={nowMs} />);
    expect(screen.getByText(/no running sessions/i)).toBeInTheDocument();
  });
});
```

- [ ] **Step 2: Run it to verify it fails**

```bash
npm run test -- --run src/features/dashboard/components/RunningTable.test.tsx
```

Expected: FAIL — component missing.

- [ ] **Step 3: Implement RunningTable**

`elixir/assets/src/features/dashboard/components/RunningTable.tsx`:

```tsx
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from "@/components/ui/table";
import type { RunningEntry } from "@/types/contract";
import { elapsedSeconds, formatDuration } from "@/lib/format";

export function RunningTable({ rows, nowMs }: { rows: RunningEntry[]; nowMs: number }) {
  if (rows.length === 0) return <p className="text-muted-foreground">No running sessions.</p>;

  return (
    <Table>
      <TableHeader>
        <TableRow>
          <TableHead>Issue</TableHead>
          <TableHead>Project</TableHead>
          <TableHead>Turns</TableHead>
          <TableHead>Tokens</TableHead>
          <TableHead>Elapsed</TableHead>
        </TableRow>
      </TableHeader>
      <TableBody>
        {rows.map((r) => {
          const secs = elapsedSeconds(r.started_at, nowMs);
          return (
            <TableRow key={r.issue_id}>
              <TableCell>{r.issue_identifier}</TableCell>
              <TableCell>{r.project?.name ?? "—"}</TableCell>
              <TableCell>{r.turn_count}</TableCell>
              <TableCell>{r.tokens.total_tokens}</TableCell>
              <TableCell>{secs === null ? "—" : formatDuration(secs)}</TableCell>
            </TableRow>
          );
        })}
      </TableBody>
    </Table>
  );
}
```

- [ ] **Step 4: Implement RetryTable (countdown to `due_at`)**

`elixir/assets/src/features/dashboard/components/RetryTable.tsx`:

```tsx
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from "@/components/ui/table";
import type { RetryEntry } from "@/types/contract";
import { formatDuration } from "@/lib/format";

function secondsUntil(iso: string | null, nowMs: number): number | null {
  if (!iso) return null;
  return Math.max(0, Math.floor((new Date(iso).getTime() - nowMs) / 1000));
}

export function RetryTable({ rows, nowMs }: { rows: RetryEntry[]; nowMs: number }) {
  if (rows.length === 0) return <p className="text-muted-foreground">No retry queue.</p>;

  return (
    <Table>
      <TableHeader>
        <TableRow>
          <TableHead>Issue</TableHead>
          <TableHead>Project</TableHead>
          <TableHead>Attempt</TableHead>
          <TableHead>Due in</TableHead>
          <TableHead>Error</TableHead>
        </TableRow>
      </TableHeader>
      <TableBody>
        {rows.map((r) => {
          const secs = secondsUntil(r.due_at, nowMs);
          return (
            <TableRow key={r.issue_id}>
              <TableCell>{r.issue_identifier}</TableCell>
              <TableCell>{r.project?.name ?? "—"}</TableCell>
              <TableCell>{r.attempt}</TableCell>
              <TableCell>{secs === null ? "—" : formatDuration(secs)}</TableCell>
              <TableCell className="max-w-xs truncate">{r.error ?? "—"}</TableCell>
            </TableRow>
          );
        })}
      </TableBody>
    </Table>
  );
}
```

- [ ] **Step 5: Implement BlockedTable**

`elixir/assets/src/features/dashboard/components/BlockedTable.tsx`:

```tsx
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from "@/components/ui/table";
import type { BlockedEntry } from "@/types/contract";

export function BlockedTable({ rows }: { rows: BlockedEntry[] }) {
  if (rows.length === 0) return <p className="text-muted-foreground">No blocked sessions.</p>;

  return (
    <Table>
      <TableHeader>
        <TableRow>
          <TableHead>Issue</TableHead>
          <TableHead>Project</TableHead>
          <TableHead>State</TableHead>
          <TableHead>Error</TableHead>
        </TableRow>
      </TableHeader>
      <TableBody>
        {rows.map((r) => (
          <TableRow key={r.issue_id}>
            <TableCell>{r.issue_identifier}</TableCell>
            <TableCell>{r.project?.name ?? "—"}</TableCell>
            <TableCell>{r.state}</TableCell>
            <TableCell className="max-w-xs truncate">{r.error ?? "—"}</TableCell>
          </TableRow>
        ))}
      </TableBody>
    </Table>
  );
}
```

- [ ] **Step 6: Run the test to verify it passes**

```bash
npm run test -- --run src/features/dashboard/components/RunningTable.test.tsx
```

Expected: PASS.

- [ ] **Step 7: Commit**

```bash
cd /work/Projekty/Harmony
git add elixir/assets/src/features/dashboard/components
git commit -m "feat(frontend): running/retry/blocked dashboard tables with live timers"
```

---

### Task 9: Assemble the Dashboard screen

**Files:**
- Modify: `elixir/assets/src/routes/DashboardPage.tsx`
- Create: `elixir/assets/src/routes/DashboardPage.test.tsx`

- [ ] **Step 1: Write a failing page test (loading → data)**

`elixir/assets/src/routes/DashboardPage.test.tsx`:

```tsx
import { render, screen, waitFor } from "@testing-library/react";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { describe, it, expect, vi, afterEach } from "vitest";
import { DashboardPage } from "@/routes/DashboardPage";

afterEach(() => vi.restoreAllMocks());

function renderPage() {
  const qc = new QueryClient({ defaultOptions: { queries: { retry: false } } });
  return render(
    <QueryClientProvider client={qc}>
      <DashboardPage />
    </QueryClientProvider>,
  );
}

describe("DashboardPage", () => {
  it("shows data after the initial fetch resolves", async () => {
    vi.stubGlobal(
      "fetch",
      vi.fn(async () =>
        new Response(
          JSON.stringify({
            generated_at: "2026-06-02T00:00:00Z",
            counts: { running: 5, retrying: 0, blocked: 0 },
            running: [],
            retrying: [],
            blocked: [],
          }),
          { status: 200, headers: { "content-type": "application/json" } },
        ),
      ),
    );

    renderPage();
    await waitFor(() => expect(screen.getByText("Running").closest("div")).toHaveTextContent("5"));
  });
});
```

- [ ] **Step 2: Run it to verify it fails**

```bash
npm run test -- --run src/routes/DashboardPage.test.tsx
```

Expected: FAIL — current `DashboardPage` is the placeholder.

- [ ] **Step 3: Implement the Dashboard screen**

`elixir/assets/src/routes/DashboardPage.tsx`:

```tsx
import { useDashboard } from "@/features/dashboard/useDashboard";
import { useNow } from "@/lib/useNow";
import { MetricCards } from "@/features/dashboard/components/MetricCards";
import { RunningTable } from "@/features/dashboard/components/RunningTable";
import { RetryTable } from "@/features/dashboard/components/RetryTable";
import { BlockedTable } from "@/features/dashboard/components/BlockedTable";
import { ConnectionStatus } from "@/features/dashboard/components/ConnectionStatus";
import { Skeleton } from "@/components/ui/skeleton";
import { Alert, AlertTitle, AlertDescription } from "@/components/ui/alert";

export function DashboardPage() {
  const { data, isLoading } = useDashboard();
  const nowMs = useNow();

  return (
    <div className="space-y-6">
      <div className="flex items-center justify-between">
        <h1 className="text-2xl font-semibold">Dashboard</h1>
        <ConnectionStatus hasData={!!data} />
      </div>

      {isLoading && !data ? (
        <Skeleton className="h-32 w-full" />
      ) : data ? (
        <>
          {data.error ? (
            <Alert variant="destructive">
              <AlertTitle>{data.error.code}</AlertTitle>
              <AlertDescription>{data.error.message}</AlertDescription>
            </Alert>
          ) : null}

          <MetricCards state={data} />

          <section>
            <h2 className="text-lg font-medium mb-2">Running sessions</h2>
            <RunningTable rows={data.running ?? []} nowMs={nowMs} />
          </section>

          <section>
            <h2 className="text-lg font-medium mb-2">Retry queue</h2>
            <RetryTable rows={data.retrying ?? []} nowMs={nowMs} />
          </section>

          <section>
            <h2 className="text-lg font-medium mb-2">Blocked sessions</h2>
            <BlockedTable rows={data.blocked ?? []} />
          </section>
        </>
      ) : (
        <p className="text-muted-foreground">No data.</p>
      )}
    </div>
  );
}
```

- [ ] **Step 4: Run the test to verify it passes**

```bash
npm run test -- --run src/routes/DashboardPage.test.tsx
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
cd /work/Projekty/Harmony
git add elixir/assets/src/routes/DashboardPage.tsx elixir/assets/src/routes/DashboardPage.test.tsx
git commit -m "feat(frontend): assemble real-time dashboard screen"
```

---

### Task 10: Remaining dashboard sections (runtime/sandbox, projects, work runs, artifacts, rate limits)

These reuse the patterns from Tasks 7–8 (a typed component reading a slice of `StatePayload`, an empty state, a Vitest test). Implement one component + one test per section, then add the section to `DashboardPage`. Field sources (from `SymphonyElixirWeb.Presenter`):

- **Runtime / sandbox** (`state.runtime?.sandbox`): `posture`, `bubblewrap_available`, `apparmor_restrict_unprivileged_userns`, `thread_sandbox`, `turn_sandbox_type`, `warnings[]`. Render as a definition list; show `warnings` as `Badge`s.
- **Projects** (`state.projects?`): per project `name`, `slug`, `counts.{running,retrying,blocked}` — a table.
- **Work runs** (`state.durable?.work_runs`): `type`, `status`, `linear_identifier`/`linear_identifier`, `github_owner/repo/pr_number`, `dedupe_key` — a table (guard on `state.durable` being present).
- **Artifacts** (`state.durable?.artifacts` and `state.artifacts`): `kind`, `path` — a table.
- **Rate limits** (`state.rate_limits`): render `JSON.stringify(state.rate_limits, null, 2)` inside a `<pre>` (matches the current "raw" dashboard rendering).

- [ ] **Step 1: For each section above, write a failing component test, implement the component, and add it to `DashboardPage`.** Follow the exact shape of `RunningTable` (Task 8 Step 3) and its test (Task 8 Step 1): typed `rows`/`state` prop, an empty state, a Vitest render assertion on one field.

- [ ] **Step 2: Run all frontend tests and build**

```bash
cd /work/Projekty/Harmony/elixir/assets
npm run test -- --run && npm run build
```

Expected: all green.

- [ ] **Step 3: Commit**

```bash
cd /work/Projekty/Harmony
git add elixir/assets/src/features/dashboard
git commit -m "feat(frontend): render remaining dashboard sections"
```

---

## Phase 1 Final Validation

- [ ] From `elixir/`: `mix format --check-formatted && mix test` exit 0 (channel test included).
- [ ] From `elixir/assets/`: `npm run lint && npm run test -- --run && npm run build` exit 0.
- [ ] **Manual gate (e2e proof of React-over-WebSocket):** start the app, open `http://localhost:5173/app/` (dev) or `/app` (built). Confirm the dashboard renders live data. Trigger an update with `curl -X POST http://localhost:<port>/api/v1/refresh` and confirm the dashboard counts/sessions update **without a page reload**.
- [ ] `/` still serves the existing LiveView dashboard unchanged.
