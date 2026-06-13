import { render, screen, waitFor } from "@testing-library/react";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { MemoryRouter } from "react-router-dom";
import { describe, it, expect, vi, afterEach } from "vitest";
import { ProjectsPage } from "@/routes/ProjectsPage";

afterEach(() => vi.restoreAllMocks());

function renderPage() {
  const qc = new QueryClient({ defaultOptions: { queries: { retry: false } } });
  return render(
    <QueryClientProvider client={qc}>
      <MemoryRouter>
        <ProjectsPage />
      </MemoryRouter>
    </QueryClientProvider>,
  );
}

describe("ProjectsPage", () => {
  it("lists projects from the API", async () => {
    vi.stubGlobal(
      "fetch",
      vi.fn(
        async () =>
          new Response(
            JSON.stringify({
              projects: [
                {
                  id: "1",
                  slug: "portal",
                  github_owner: "dezet",
                  github_repo: "portal",
                  github_base_branch: "main",
                  linear_team_key: "COD",
                  linear_project_slug: "p",
                  linear_human_review_state: "Human Review",
                  config_version: 2,
                  config: {},
                  inserted_at: "",
                  updated_at: "",
                },
              ],
            }),
            { status: 200, headers: { "content-type": "application/json" } },
          ),
      ),
    );

    renderPage();
    await waitFor(() => expect(screen.getByText("portal")).toBeInTheDocument());
    expect(screen.getByText("dezet/portal")).toBeInTheDocument();
  });

  it("shows an empty state when no projects exist", async () => {
    vi.stubGlobal(
      "fetch",
      vi.fn(
        async () =>
          new Response(JSON.stringify({ projects: [] }), {
            status: 200,
            headers: { "content-type": "application/json" },
          }),
      ),
    );

    renderPage();

    expect(await screen.findByText("No projects configured")).toBeInTheDocument();
    expect(screen.getByRole("link", { name: /new project/i })).toHaveAttribute(
      "href",
      "/projects/new",
    );
  });

  it("shows an error state when projects cannot be loaded", async () => {
    vi.stubGlobal(
      "fetch",
      vi.fn(
        async () =>
          new Response(
            JSON.stringify({
              error: { code: "db_down", message: "Database unavailable" },
            }),
            { status: 500, headers: { "content-type": "application/json" } },
          ),
      ),
    );

    renderPage();

    expect(await screen.findByText("Could not load projects")).toBeInTheDocument();
    expect(screen.getByText("Database unavailable")).toBeInTheDocument();
  });
});
