import { render, screen, waitFor } from "@testing-library/react";
import { MemoryRouter } from "react-router-dom";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { describe, it, expect, vi, afterEach } from "vitest";
import { WorkTab } from "@/features/project/WorkTab";
import type { ProjectSummary } from "@/types/contract";
import summaryFixture from "@/test/fixtures/project_summary.fixture.json";
import workRunsFixture from "@/test/fixtures/work_runs_page.fixture.json";

afterEach(() => vi.restoreAllMocks());

function renderTab(summary: ProjectSummary, slug: string) {
  vi.stubGlobal(
    "fetch",
    vi.fn(async () =>
      new Response(JSON.stringify(workRunsFixture), {
        status: 200,
        headers: { "content-type": "application/json" },
      }),
    ),
  );
  const qc = new QueryClient({ defaultOptions: { queries: { retry: false } } });
  return render(
    <QueryClientProvider client={qc}>
      <MemoryRouter>
        <WorkTab summary={summary} slug={slug} />
      </MemoryRouter>
    </QueryClientProvider>,
  );
}

describe("WorkTab", () => {
  it("renders three column headings", () => {
    renderTab(summaryFixture as ProjectSummary, "alpha");
    expect(screen.getByText("Running")).toBeInTheDocument();
    expect(screen.getByText("Retry & blocked")).toBeInTheDocument();
    expect(screen.getByText("→ Human Review")).toBeInTheDocument();
  });

  it("shows running entry from fixture", () => {
    renderTab(summaryFixture as ProjectSummary, "alpha");
    // issue_identifier from running fixture entry (may appear in multiple columns)
    const matches = screen.getAllByText("COD-10");
    expect(matches.length).toBeGreaterThan(0);
  });

  it("shows blocked entry in RetryBlocked column", () => {
    renderTab(summaryFixture as ProjectSummary, "alpha");
    expect(screen.getByText("COD-12")).toBeInTheDocument();
  });

  it("shows PR link in HumanReview column", () => {
    renderTab(summaryFixture as ProjectSummary, "alpha");
    const pr = summaryFixture.human_review_prs[0];
    const link = screen.getByRole("link", { name: `#${pr.github_pr_number}` });
    expect(link).toBeInTheDocument();
    expect(link).toHaveAttribute(
      "href",
      `https://github.com/${pr.github_owner}/${pr.github_repo}/pull/${pr.github_pr_number}`,
    );
  });

  it("shows History section with work run rows", async () => {
    renderTab(summaryFixture as ProjectSummary, "alpha");
    expect(screen.getByRole("heading", { name: /history/i })).toBeInTheDocument();
    await waitFor(() =>
      expect(screen.getAllByText("COD-10").length).toBeGreaterThan(0),
    );
  });

  it("shows empty state for running when list is empty", () => {
    const empty: ProjectSummary = {
      ...summaryFixture as ProjectSummary,
      running: [],
      retrying: [],
      blocked: [],
      human_review_prs: [],
    };
    renderTab(empty, "alpha");
    expect(screen.getByText("No runs in progress.")).toBeInTheDocument();
    expect(screen.getByText("Nothing stuck.")).toBeInTheDocument();
    expect(screen.getByText("Nothing waiting for review.")).toBeInTheDocument();
  });
});
