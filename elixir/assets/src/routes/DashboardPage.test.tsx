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
      vi.fn(
        async () =>
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
    // running count 5 is distinct; presence confirms the snapshot rendered.
    await waitFor(() => expect(screen.getByText("5")).toBeInTheDocument());
    expect(screen.getByText("Running")).toBeInTheDocument();
  });

  it("renders runtime and durable evidence artifacts", async () => {
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
              artifacts: [{ kind: "runtime_log", path: "/tmp/runtime.log" }],
              durable: {
                artifacts: [
                  { id: "artifact-1", kind: "screenshot", path: "/tmp/screenshot.png" },
                ],
              },
            }),
            { status: 200, headers: { "content-type": "application/json" } },
          ),
      ),
    );

    renderPage();

    await waitFor(() =>
      expect(screen.getByRole("heading", { name: "Evidence artifacts" })).toBeInTheDocument(),
    );
    expect(screen.getByText("/tmp/runtime.log")).toBeInTheDocument();
    expect(screen.getByText("/tmp/screenshot.png")).toBeInTheDocument();
  });
});
