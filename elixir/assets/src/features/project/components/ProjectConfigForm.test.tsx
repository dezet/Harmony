import { render, screen, waitFor } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { describe, it, expect, vi, afterEach } from "vitest";
import { ProjectConfigForm } from "@/features/project/components/ProjectConfigForm";
import type { Project } from "@/types/contract";

// Mock JsonEditor so CodeMirror doesn't interfere with jsdom testing
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

const sampleProject: Project = {
  id: "project-1",
  slug: "portal",
  github_owner: "dezet",
  github_repo: "portal",
  github_base_branch: "develop",
  forge_secret: "set",
  tracker_secret: "unset",
  linear_project_slug: "portal-linear",
  linear_team_key: "COD",
  linear_human_review_state: "Human Review",
  config_version: 3,
  config: { review: { trigger: "@hreview" } },
  inserted_at: "2026-01-01T00:00:00Z",
  updated_at: "2026-01-01T00:00:00Z",
};

function renderForm(props: Parameters<typeof ProjectConfigForm>[0] = {}) {
  const qc = new QueryClient({
    defaultOptions: { queries: { retry: false }, mutations: { retry: false } },
  });
  return render(
    <QueryClientProvider client={qc}>
      <ProjectConfigForm {...props} />
    </QueryClientProvider>,
  );
}

describe("ProjectConfigForm (create mode)", () => {
  it("shows a validation error when slug is empty", async () => {
    renderForm();
    await userEvent.click(screen.getByRole("button", { name: /save/i }));
    expect(await screen.findByText(/slug is required/i)).toBeInTheDocument();
  });

  it("calls create API and onSuccess on successful submit", async () => {
    vi.stubGlobal(
      "fetch",
      vi.fn(
        async () =>
          new Response(JSON.stringify({ project: { id: "new-project" } }), {
            status: 201,
            headers: { "content-type": "application/json" },
          }),
      ),
    );
    const onSuccess = vi.fn();
    renderForm({ onSuccess });

    await userEvent.type(screen.getByLabelText("Slug"), "portal");
    await userEvent.type(screen.getByLabelText("GitHub owner"), "dezet");
    await userEvent.type(screen.getByLabelText("GitHub repo"), "portal");
    await userEvent.type(screen.getByLabelText("Base branch"), "main");
    await userEvent.click(screen.getByRole("button", { name: /save/i }));

    await waitFor(() => expect(onSuccess).toHaveBeenCalledTimes(1));
  });
});

describe("ProjectConfigForm (edit mode)", () => {
  it("pre-fills form fields from the project prop", async () => {
    renderForm({ project: sampleProject });

    expect(await screen.findByLabelText("Slug")).toHaveValue("portal");
    expect(screen.getByLabelText("GitHub owner")).toHaveValue("dezet");
    expect(screen.getByLabelText("Base branch")).toHaveValue("develop");
    expect(screen.getByLabelText("Config (JSON)")).toHaveValue(
      JSON.stringify({ review: { trigger: "@hreview" } }, null, 2),
    );
  });

  it("calls update API and onSuccess on successful submit", async () => {
    const fetchMock = vi.fn(async (input: RequestInfo | URL, init?: RequestInit) => {
      const url = input.toString();
      if (url.endsWith("/api/v1/projects/project-1") && init?.method === "PUT") {
        return new Response(JSON.stringify({ project: sampleProject }), {
          status: 200,
          headers: { "content-type": "application/json" },
        });
      }
      return new Response(JSON.stringify({ project: sampleProject }), {
        status: 200,
        headers: { "content-type": "application/json" },
      });
    });
    vi.stubGlobal("fetch", fetchMock);

    const onSuccess = vi.fn();
    renderForm({ project: sampleProject, onSuccess });

    await waitFor(() => expect(screen.getByLabelText("Slug")).toHaveValue("portal"));

    const baseBranch = screen.getByLabelText("Base branch");
    await userEvent.clear(baseBranch);
    await userEvent.type(baseBranch, "main");
    await userEvent.click(screen.getByRole("button", { name: /save/i }));

    await waitFor(() => expect(onSuccess).toHaveBeenCalledTimes(1));

    const updateCall = fetchMock.mock.calls.find(
      ([input, init]) =>
        (input as string).endsWith("/api/v1/projects/project-1") &&
        (init as RequestInit)?.method === "PUT",
    );
    expect(updateCall).toBeDefined();
    expect(JSON.parse((updateCall?.[1] as RequestInit)?.body as string)).toMatchObject({
      github_base_branch: "main",
    });
  });

  it("shows the current secret state and never pre-fills the value", async () => {
    renderForm({ project: sampleProject });

    expect(await screen.findByText(/Forge token — currently: set/i)).toBeInTheDocument();
    expect(screen.getByText(/Tracker key — currently: unset/i)).toBeInTheDocument();
    expect(screen.getByLabelText(/Forge token/i)).toHaveValue("");
  });

  it("sends a typed forge_secret and the clear flag in the update body", async () => {
    const fetchMock = vi.fn(
      async (_input: RequestInfo | URL, _init?: RequestInit) =>
        new Response(JSON.stringify({ project: sampleProject }), {
          status: 200,
          headers: { "content-type": "application/json" },
        }),
    );
    vi.stubGlobal("fetch", fetchMock);

    renderForm({ project: sampleProject });
    await waitFor(() => expect(screen.getByLabelText("Slug")).toHaveValue("portal"));

    await userEvent.type(screen.getByLabelText(/Forge token/i), "ghp_new");
    // Two clear checkboxes: [0] forge, [1] tracker. Check the tracker one.
    await userEvent.click(screen.getAllByRole("checkbox")[1]);
    await userEvent.click(screen.getByRole("button", { name: /save/i }));

    await waitFor(() => expect(fetchMock).toHaveBeenCalled());
    const putCall = fetchMock.mock.calls.find(
      ([input, init]) =>
        (input as string).endsWith("/api/v1/projects/project-1") &&
        (init as RequestInit)?.method === "PUT",
    );
    const body = JSON.parse((putCall?.[1] as RequestInit)?.body as string);
    expect(body.forge_secret).toBe("ghp_new");
    expect(body.clear_tracker_secret).toBe(true);
    expect(body).not.toHaveProperty("clear_forge_secret");
  });

  it("maps a server config error onto the JSON field", async () => {
    vi.stubGlobal(
      "fetch",
      vi.fn(
        async () =>
          new Response(
            JSON.stringify({
              error: {
                code: "validation_failed",
                message: "Validation failed",
                fields: { config: ["must be a JSON object"] },
              },
            }),
            { status: 422, headers: { "content-type": "application/json" } },
          ),
      ),
    );

    renderForm({ project: sampleProject });
    await waitFor(() => expect(screen.getByLabelText("Slug")).toHaveValue("portal"));

    await userEvent.click(screen.getByRole("button", { name: /save/i }));

    expect(await screen.findByText("must be a JSON object")).toBeInTheDocument();
  });
});
