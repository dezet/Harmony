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
