import { render, screen, waitFor } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { MemoryRouter, Routes, Route } from "react-router-dom";
import { describe, it, expect, vi, afterEach } from "vitest";
import { ProjectFormPage } from "@/routes/ProjectFormPage";

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

function renderForm() {
  const qc = new QueryClient({
    defaultOptions: { queries: { retry: false }, mutations: { retry: false } },
  });
  return render(
    <QueryClientProvider client={qc}>
      <MemoryRouter initialEntries={["/projects/new"]}>
        <Routes>
          <Route path="/projects/new" element={<ProjectFormPage />} />
          <Route path="/projects" element={<div>Projects list</div>} />
        </Routes>
      </MemoryRouter>
    </QueryClientProvider>,
  );
}

function renderEditForm(id = "project-1") {
  const qc = new QueryClient({
    defaultOptions: { queries: { retry: false }, mutations: { retry: false } },
  });
  return render(
    <QueryClientProvider client={qc}>
      <MemoryRouter initialEntries={[`/projects/${id}/edit`]}>
        <Routes>
          <Route path="/projects/:id/edit" element={<ProjectFormPage />} />
          <Route path="/projects" element={<div>Projects list</div>} />
        </Routes>
      </MemoryRouter>
    </QueryClientProvider>,
  );
}

describe("ProjectFormPage (create)", () => {
  it("shows a validation error when slug is empty", async () => {
    renderForm();
    await userEvent.click(screen.getByRole("button", { name: /save/i }));
    expect(await screen.findByText(/slug is required/i)).toBeInTheDocument();
  });

  it("submits and navigates to the list on success", async () => {
    vi.stubGlobal(
      "fetch",
      vi.fn(async (input: RequestInfo | URL) => {
        if (input.toString().endsWith("/api/v1/forge/repositories")) {
          return new Response(
            JSON.stringify({
              repositories: [{ owner: "dezet", name: "portal", default_branch: "main", url: "u" }],
              truncated: false,
            }),
            { status: 200, headers: { "content-type": "application/json" } },
          );
        }
        return new Response(JSON.stringify({ project: { id: "1" } }), {
          status: 201,
          headers: { "content-type": "application/json" },
        });
      }),
    );

    renderForm();
    await userEvent.type(screen.getByLabelText("Slug"), "portal");
    await userEvent.click(screen.getByRole("button", { name: "Repository" }));
    await screen.findByRole("option", { name: /dezet\/portal/i });
    await userEvent.click(screen.getByRole("option", { name: /dezet\/portal/i }));
    await userEvent.click(screen.getByRole("button", { name: /save/i }));

    await waitFor(() => expect(screen.getByText("Projects list")).toBeInTheDocument());
  });

  it("maps a server config error onto the JSON textarea field", async () => {
    vi.stubGlobal(
      "fetch",
      vi.fn(async (input: RequestInfo | URL) => {
        if (input.toString().endsWith("/api/v1/forge/repositories")) {
          return new Response(
            JSON.stringify({
              repositories: [{ owner: "dezet", name: "portal", default_branch: "main", url: "u" }],
              truncated: false,
            }),
            { status: 200, headers: { "content-type": "application/json" } },
          );
        }
        return new Response(
          JSON.stringify({
            error: {
              code: "validation_failed",
              message: "Validation failed",
              fields: { config: ["must be a JSON object"] },
            },
          }),
          { status: 422, headers: { "content-type": "application/json" } },
        );
      }),
    );

    renderForm();
    await userEvent.type(screen.getByLabelText("Slug"), "portal");
    await userEvent.click(screen.getByRole("button", { name: "Repository" }));
    await screen.findByRole("option", { name: /dezet\/portal/i });
    await userEvent.click(screen.getByRole("option", { name: /dezet\/portal/i }));
    await userEvent.click(screen.getByRole("button", { name: /save/i }));

    expect(await screen.findByText("must be a JSON object")).toBeInTheDocument();
    expect(screen.getByLabelText("Config (JSON)")).toHaveAccessibleDescription(
      "must be a JSON object",
    );
  });

  it("disables save while create is pending", async () => {
    vi.stubGlobal(
      "fetch",
      vi.fn((input: RequestInfo | URL) => {
        if (input.toString().endsWith("/api/v1/forge/repositories")) {
          return Promise.resolve(
            new Response(
              JSON.stringify({
                repositories: [{ owner: "dezet", name: "portal", default_branch: "main", url: "u" }],
                truncated: false,
              }),
              { status: 200, headers: { "content-type": "application/json" } },
            ),
          );
        }
        // Keep the create mutation pending so the button state is observable.
        return new Promise<Response>(() => {});
      }),
    );

    renderForm();
    await userEvent.type(screen.getByLabelText("Slug"), "portal");
    await userEvent.click(screen.getByRole("button", { name: "Repository" }));
    await screen.findByRole("option", { name: /dezet\/portal/i });
    await userEvent.click(screen.getByRole("option", { name: /dezet\/portal/i }));
    await userEvent.click(screen.getByRole("button", { name: /save/i }));

    await waitFor(() => expect(screen.getByRole("button", { name: /save/i })).toBeDisabled());
  });
});

describe("ProjectFormPage (edit)", () => {
  it("hydrates the edit form from the loaded project", async () => {
    vi.stubGlobal(
      "fetch",
      vi.fn(
        async () =>
          new Response(
            JSON.stringify({
              project: {
                id: "project-1",
                slug: "portal",
                github_owner: "dezet",
                github_repo: "portal",
                github_base_branch: "develop",
                linear_project_slug: "portal-linear",
                linear_team_key: "COD",
                linear_human_review_state: "Human Review",
                config_version: 3,
                config: { review: { trigger: "@hreview" } },
                inserted_at: "",
                updated_at: "",
              },
            }),
            { status: 200, headers: { "content-type": "application/json" } },
          ),
      ),
    );

    renderEditForm();

    expect(await screen.findByLabelText("Slug")).toHaveValue("portal");
    expect(screen.getByDisplayValue("develop")).toBeInTheDocument();
    expect(screen.getByLabelText("Config (JSON)")).toHaveValue(
      JSON.stringify({ review: { trigger: "@hreview" } }, null, 2),
    );
  });

  it("shows an error state when the edit project cannot be loaded", async () => {
    vi.stubGlobal(
      "fetch",
      vi.fn(
        async () =>
          new Response(
            JSON.stringify({ error: { code: "not_found", message: "Project not found" } }),
            { status: 404, headers: { "content-type": "application/json" } },
          ),
      ),
    );

    renderEditForm();

    expect(await screen.findByText("Could not load project")).toBeInTheDocument();
    expect(screen.getByText("Project not found")).toBeInTheDocument();
    expect(screen.getByRole("link", { name: /back to projects/i })).toHaveAttribute(
      "href",
      "/projects",
    );
  });

  it("updates the loaded project and navigates to the list", async () => {
    const fetchMock = vi.fn(async (input: RequestInfo | URL, init?: RequestInit) => {
      const url = input.toString();

      if (url.endsWith("/api/v1/projects/project-1") && init?.method === "PUT") {
        return new Response(JSON.stringify({ project: { id: "project-1" } }), {
          status: 200,
          headers: { "content-type": "application/json" },
        });
      }

      return new Response(
        JSON.stringify({
          project: {
            id: "project-1",
            slug: "portal",
            github_owner: "dezet",
            github_repo: "portal",
            github_base_branch: "main",
            linear_project_slug: null,
            linear_team_key: null,
            linear_human_review_state: null,
            config_version: 1,
            config: {},
            inserted_at: "",
            updated_at: "",
          },
        }),
        { status: 200, headers: { "content-type": "application/json" } },
      );
    });
    vi.stubGlobal("fetch", fetchMock);

    renderEditForm();

    await waitFor(() => expect(screen.getByLabelText("Base branch")).toHaveValue("main"));
    await userEvent.click(screen.getByRole("button", { name: /save/i }));

    await waitFor(() => expect(screen.getByText("Projects list")).toBeInTheDocument());

    const updateCall = fetchMock.mock.calls.find(
      ([input, init]) => input.toString().endsWith("/api/v1/projects/project-1") && init?.method === "PUT",
    );
    expect(updateCall).toBeDefined();
    expect(JSON.parse(updateCall?.[1]?.body as string)).toMatchObject({
      github_base_branch: "main",
    });
  });
});
