import { render, screen, waitFor } from "@testing-library/react";
import { MemoryRouter, Routes, Route } from "react-router-dom";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { describe, it, expect, vi, afterEach } from "vitest";
import { ProjectWorkspacePage } from "@/features/project/ProjectWorkspacePage";
import summaryFixture from "@/test/fixtures/project_summary.fixture.json";
import workRunsFixture from "@/test/fixtures/work_runs_page.fixture.json";

afterEach(() => vi.restoreAllMocks());

function renderAtSlug(slug: string, fetchImpl: (url: string, init?: RequestInit) => Promise<Response>) {
  vi.stubGlobal("fetch", vi.fn(fetchImpl));
  const qc = new QueryClient({ defaultOptions: { queries: { retry: false } } });
  return render(
    <QueryClientProvider client={qc}>
      <MemoryRouter initialEntries={[`/projects/${slug}`]}>
        <Routes>
          <Route path="projects/:slug" element={<ProjectWorkspacePage />} />
        </Routes>
      </MemoryRouter>
    </QueryClientProvider>,
  );
}

describe("ProjectWorkspacePage", () => {
  it("renders header, tabs, and work tab content from summary fixture", async () => {
    renderAtSlug("alpha", async (url: string) => {
      if ((url as string).includes("/work_runs")) {
        return new Response(JSON.stringify(workRunsFixture), {
          status: 200,
          headers: { "content-type": "application/json" },
        });
      }
      return new Response(JSON.stringify(summaryFixture), {
        status: 200,
        headers: { "content-type": "application/json" },
      });
    });

    // h1 with the project slug from fixture
    await waitFor(() =>
      expect(screen.getByRole("heading", { name: summaryFixture.project.slug })).toBeInTheDocument(),
    );

    // Tab bar: Work enabled, Evidence disabled
    const workTab = screen.getByRole("button", { name: /work/i });
    expect(workTab).toBeInTheDocument();
    expect(workTab).not.toBeDisabled();

    const evidenceTab = screen.getByRole("button", { name: /evidence/i });
    expect(evidenceTab).toBeDisabled();

    // Three column headings
    expect(screen.getByText("Running")).toBeInTheDocument();
    expect(screen.getByText("Retry & blocked")).toBeInTheDocument();
    expect(screen.getByText("→ Human Review")).toBeInTheDocument();

    // PR link from fixture
    const prNumber = summaryFixture.human_review_prs[0].github_pr_number;
    const prLink = screen.getByRole("link", { name: `#${prNumber}` });
    expect(prLink).toBeInTheDocument();
    expect(prLink).toHaveAttribute("target", "_blank");

    // History section
    expect(screen.getByRole("heading", { name: /history/i })).toBeInTheDocument();

    // A row from work_runs fixture
    await waitFor(() =>
      expect(screen.getAllByText("COD-10").length).toBeGreaterThan(0),
    );
  });

  it("shows not-found state when summary returns 404", async () => {
    renderAtSlug("nonexistent", async () =>
      new Response(
        JSON.stringify({ error: { code: "not_found", message: "Project not found" } }),
        { status: 404, headers: { "content-type": "application/json" } },
      ),
    );

    await waitFor(() =>
      expect(screen.getByText("Project not found")).toBeInTheDocument(),
    );

    const backLink = screen.getByRole("link", { name: /projects/i });
    expect(backLink).toHaveAttribute("href", "/projects");
  });
});
