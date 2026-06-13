import { render, screen, waitFor } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { MemoryRouter, Routes, Route, useLocation } from "react-router-dom";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { describe, it, expect, vi, afterEach } from "vitest";
import { ProjectWorkspacePage } from "@/features/project/ProjectWorkspacePage";
import summaryFixture from "@/test/fixtures/project_summary.fixture.json";
import workRunsFixture from "@/test/fixtures/work_runs_page.fixture.json";

afterEach(() => vi.restoreAllMocks());

/**
 * Helper that mounts a tiny component inside the same router to expose
 * the current location's search string in the DOM for assertions.
 */
function LocationDisplay() {
  const location = useLocation();
  return <div data-testid="location">{location.pathname}{location.search}</div>;
}

function makeSuccessFetch(url: string): Promise<Response> {
  if ((url as string).includes("/work_runs")) {
    return Promise.resolve(
      new Response(JSON.stringify(workRunsFixture), {
        status: 200,
        headers: { "content-type": "application/json" },
      }),
    );
  }
  return Promise.resolve(
    new Response(JSON.stringify(summaryFixture), {
      status: 200,
      headers: { "content-type": "application/json" },
    }),
  );
}

function renderAtPath(
  initialPath: string,
  fetchImpl: (url: string, init?: RequestInit) => Promise<Response>,
) {
  vi.stubGlobal("fetch", vi.fn(fetchImpl));
  const qc = new QueryClient({ defaultOptions: { queries: { retry: false } } });
  return render(
    <QueryClientProvider client={qc}>
      <MemoryRouter initialEntries={[initialPath]}>
        <Routes>
          <Route path="projects/:slug" element={<ProjectWorkspacePage />} />
        </Routes>
        <LocationDisplay />
      </MemoryRouter>
    </QueryClientProvider>,
  );
}

/** Convenience wrapper for the common success case */
function renderAtSlug(slug: string, path?: string) {
  return renderAtPath(path ?? `/projects/${slug}`, makeSuccessFetch);
}

describe("ProjectWorkspacePage", () => {
  it("renders header, tabs, and work tab content from summary fixture", async () => {
    renderAtSlug("alpha");

    // h1 with the project slug from fixture
    await waitFor(() =>
      expect(screen.getByRole("heading", { name: summaryFixture.project.slug })).toBeInTheDocument(),
    );

    // Tab bar: Work enabled, Evidence enabled (no longer disabled)
    const workTab = screen.getByRole("button", { name: /^work$/i });
    expect(workTab).toBeInTheDocument();
    expect(workTab).not.toBeDisabled();

    const evidenceTab = screen.getByRole("button", { name: /^evidence$/i });
    expect(evidenceTab).not.toBeDisabled();

    const activityTab = screen.getByRole("button", { name: /^activity$/i });
    expect(activityTab).not.toBeDisabled();

    const configTab = screen.getByRole("button", { name: /^configuration$/i });
    expect(configTab).not.toBeDisabled();

    // Three column headings (Work tab content)
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
    renderAtPath("/projects/nonexistent", async () =>
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

  it("clicking the Evidence tab updates the URL to include ?tab=evidence", async () => {
    const user = userEvent.setup();
    renderAtSlug("alpha");

    // Wait for page to load
    await waitFor(() =>
      expect(screen.getByRole("heading", { name: summaryFixture.project.slug })).toBeInTheDocument(),
    );

    const evidenceTab = screen.getByRole("button", { name: /^evidence$/i });
    await user.click(evidenceTab);

    // Location display should now include ?tab=evidence
    await waitFor(() =>
      expect(screen.getByTestId("location").textContent).toContain("tab=evidence"),
    );

    // Evidence stub panel should be visible
    expect(screen.getByRole("heading", { name: /^evidence$/i })).toBeInTheDocument();
    expect(screen.getByText("Coming soon.")).toBeInTheDocument();
  });

  it("clicking Work tab clears the tab param from the URL", async () => {
    const user = userEvent.setup();
    renderAtSlug("alpha", "/projects/alpha?tab=evidence");

    // Wait for page to load with evidence tab active
    await waitFor(() =>
      expect(screen.getByRole("heading", { name: /^evidence$/i })).toBeInTheDocument(),
    );

    // Click Work tab
    const workTab = screen.getByRole("button", { name: /^work$/i });
    await user.click(workTab);

    // Location should no longer have ?tab=
    await waitFor(() =>
      expect(screen.getByTestId("location").textContent).not.toContain("tab="),
    );

    // Work tab content should be active
    expect(screen.getByText("Running")).toBeInTheDocument();
  });

  it("renders Activity stub when initialEntries includes ?tab=activity", async () => {
    renderAtSlug("alpha", "/projects/alpha?tab=activity");

    // Wait for page to load
    await waitFor(() =>
      expect(screen.getByRole("heading", { name: summaryFixture.project.slug })).toBeInTheDocument(),
    );

    // Activity stub panel should be visible
    expect(screen.getByRole("heading", { name: /^activity$/i })).toBeInTheDocument();
    expect(screen.getByText("Coming soon.")).toBeInTheDocument();

    // Work tab content should NOT be rendered
    expect(screen.queryByText("Running")).not.toBeInTheDocument();
  });

  it("invalid ?tab=bogus falls back to Work tab", async () => {
    renderAtSlug("alpha", "/projects/alpha?tab=bogus");

    // Wait for page to load
    await waitFor(() =>
      expect(screen.getByRole("heading", { name: summaryFixture.project.slug })).toBeInTheDocument(),
    );

    // Work tab content should be visible (fallback)
    expect(screen.getByText("Running")).toBeInTheDocument();

    // No stub "Coming soon." should be visible
    expect(screen.queryByText("Coming soon.")).not.toBeInTheDocument();
  });

  it("renders Configuration stub when ?tab=configuration", async () => {
    renderAtSlug("alpha", "/projects/alpha?tab=configuration");

    await waitFor(() =>
      expect(screen.getByRole("heading", { name: summaryFixture.project.slug })).toBeInTheDocument(),
    );

    expect(screen.getByRole("heading", { name: /^configuration$/i })).toBeInTheDocument();
    expect(screen.getByText("Coming soon.")).toBeInTheDocument();
    expect(screen.queryByText("Running")).not.toBeInTheDocument();
  });
});
