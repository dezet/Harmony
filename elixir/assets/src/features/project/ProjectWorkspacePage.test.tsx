import { render, screen, waitFor } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { MemoryRouter, Routes, Route, useLocation } from "react-router-dom";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { describe, it, expect, vi, afterEach } from "vitest";
import { ProjectWorkspacePage } from "@/features/project/ProjectWorkspacePage";
import summaryFixture from "@/test/fixtures/project_summary.fixture.json";
import workRunsFixture from "@/test/fixtures/work_runs_page.fixture.json";
import artifactsFixture from "@/test/fixtures/project_artifacts_page.fixture.json";
import activityFixture from "@/test/fixtures/project_activity_page.fixture.json";

vi.mock("@/components/JsonEditor", () => ({
  JsonEditor: ({
    value,
    onChange,
    ariaLabel,
    ariaDescribedBy,
  }: {
    value: string;
    onChange: (v: string) => void;
    ariaLabel?: string;
    ariaDescribedBy?: string;
  }) => (
    <textarea
      aria-label={ariaLabel}
      aria-describedby={ariaDescribedBy}
      value={value}
      onChange={(e) => onChange(e.target.value)}
    />
  ),
}));

afterEach(() => vi.restoreAllMocks());

/**
 * Helper that mounts a tiny component inside the same router to expose
 * the current location's search string in the DOM for assertions.
 */
function LocationDisplay() {
  const location = useLocation();
  return <div data-testid="location">{location.pathname}{location.search}</div>;
}

const projectDetailFixture = {
  project: {
    id: summaryFixture.project.id,
    slug: summaryFixture.project.slug,
    github_owner: summaryFixture.project.github_owner,
    github_repo: summaryFixture.project.github_repo,
    github_base_branch: summaryFixture.project.github_base_branch,
    linear_project_slug: summaryFixture.project.linear_project_slug,
    linear_team_key: summaryFixture.project.linear_team_key,
    linear_human_review_state: summaryFixture.project.linear_human_review_state,
    config_version: summaryFixture.project.config_version,
    config: {},
    inserted_at: "2026-01-01T00:00:00Z",
    updated_at: "2026-01-01T00:00:00Z",
  },
};

function makeSuccessFetch(url: string): Promise<Response> {
  if ((url as string).includes("/work_runs")) {
    return Promise.resolve(
      new Response(JSON.stringify(workRunsFixture), {
        status: 200,
        headers: { "content-type": "application/json" },
      }),
    );
  }
  if ((url as string).includes("/summary")) {
    return Promise.resolve(
      new Response(JSON.stringify(summaryFixture), {
        status: 200,
        headers: { "content-type": "application/json" },
      }),
    );
  }
  if ((url as string).includes("/artifacts")) {
    return Promise.resolve(
      new Response(JSON.stringify(artifactsFixture), {
        status: 200,
        headers: { "content-type": "application/json" },
      }),
    );
  }
  if ((url as string).includes("/activity")) {
    return Promise.resolve(
      new Response(JSON.stringify({ ...activityFixture, meta: { next_cursor: null } }), {
        status: 200,
        headers: { "content-type": "application/json" },
      }),
    );
  }
  // Project detail fetch (for ConfigurationTab)
  return Promise.resolve(
    new Response(JSON.stringify(projectDetailFixture), {
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

    // EvidenceTab should mount (real tab, no stub)
    expect(screen.queryByText("Coming soon.")).not.toBeInTheDocument();
  });

  it("clicking Work tab clears the tab param from the URL", async () => {
    const user = userEvent.setup();
    renderAtSlug("alpha", "/projects/alpha?tab=evidence");

    // Wait for page to load (evidence tab active — real EvidenceTab mounts)
    await waitFor(() =>
      expect(screen.getByRole("heading", { name: summaryFixture.project.slug })).toBeInTheDocument(),
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

  it("renders ActivityTab when initialEntries includes ?tab=activity", async () => {
    renderAtSlug("alpha", "/projects/alpha?tab=activity");

    // Wait for page to load
    await waitFor(() =>
      expect(screen.getByRole("heading", { name: summaryFixture.project.slug })).toBeInTheDocument(),
    );

    // ActivityTab should mount (real tab, no stub)
    expect(screen.queryByText("Coming soon.")).not.toBeInTheDocument();

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

  it("renders ConfigurationTab (with form) when ?tab=configuration", async () => {
    renderAtSlug("alpha", "/projects/alpha?tab=configuration");

    await waitFor(() =>
      expect(screen.getByRole("heading", { name: summaryFixture.project.slug })).toBeInTheDocument(),
    );

    // The ConfigurationTab renders the project form once the project loads
    await waitFor(() =>
      expect(screen.getByLabelText("Slug")).toBeInTheDocument(),
    );
    expect(screen.queryByText("Running")).not.toBeInTheDocument();
  });
});
