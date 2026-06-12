import { render, screen, waitFor, within } from "@testing-library/react";
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
  it("shows the sidebar nav and the overview at /", async () => {
    renderAt("/");
    expect(screen.getByRole("navigation", { name: "Main" })).toBeInTheDocument();
    expect(screen.getByRole("navigation", { name: "Breadcrumb" })).toBeInTheDocument();
    await waitFor(() =>
      expect(screen.getByRole("heading", { name: "Overview" })).toBeInTheDocument(),
    );
  });

  it("shows the projects page at /projects", () => {
    renderAt("/projects");
    expect(screen.getByRole("heading", { name: /projects/i })).toBeInTheDocument();
  });

  it("shows a not-found page for unknown routes", () => {
    renderAt("/nope");
    expect(within(screen.getByRole("main")).getByText(/not found/i)).toBeInTheDocument();
  });
});
