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
