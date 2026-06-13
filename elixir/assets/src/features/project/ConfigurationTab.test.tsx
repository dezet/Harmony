import { render, screen, waitFor } from "@testing-library/react";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { describe, it, expect, vi, afterEach } from "vitest";
import { ConfigurationTab } from "@/features/project/ConfigurationTab";

// Mock JsonEditor so CodeMirror doesn't interfere with jsdom
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

// Mock sonner so toast calls don't fail in jsdom
vi.mock("sonner", () => ({ toast: { success: vi.fn(), error: vi.fn() } }));

afterEach(() => vi.restoreAllMocks());

const projectDetailResponse = {
  project: {
    id: "proj-1",
    slug: "alpha",
    github_owner: "acme",
    github_repo: "portal",
    github_base_branch: "main",
    linear_project_slug: null,
    linear_team_key: null,
    linear_human_review_state: null,
    config_version: 1,
    config: {},
    inserted_at: "2026-01-01T00:00:00Z",
    updated_at: "2026-01-01T00:00:00Z",
  },
};

function makeQC() {
  return new QueryClient({ defaultOptions: { queries: { retry: false }, mutations: { retry: false } } });
}

function renderTab(props: Parameters<typeof ConfigurationTab>[0], qc = makeQC()) {
  return render(
    <QueryClientProvider client={qc}>
      <ConfigurationTab {...props} />
    </QueryClientProvider>,
  );
}

describe("ConfigurationTab", () => {
  it("does NOT fetch project when active=false", async () => {
    const fetchMock = vi.fn();
    vi.stubGlobal("fetch", fetchMock);

    renderTab({ projectId: "proj-1", slug: "alpha", active: false });

    // Give React time to settle
    await new Promise((r) => setTimeout(r, 50));

    expect(fetchMock).not.toHaveBeenCalled();
    // Should render nothing (no project data yet, not active)
    expect(screen.queryByLabelText("Slug")).not.toBeInTheDocument();
  });

  it("fetches and renders the project form when active=true", async () => {
    vi.stubGlobal(
      "fetch",
      vi.fn(
        async () =>
          new Response(JSON.stringify(projectDetailResponse), {
            status: 200,
            headers: { "content-type": "application/json" },
          }),
      ),
    );

    renderTab({ projectId: "proj-1", slug: "alpha", active: true });

    await waitFor(() => expect(screen.getByLabelText("Slug")).toBeInTheDocument());
    expect(screen.getByLabelText("Slug")).toHaveValue("alpha");
  });

  it("shows destructive alert when project fetch fails", async () => {
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

    renderTab({ projectId: "proj-1", slug: "alpha", active: true });

    await waitFor(() =>
      expect(screen.getByText(/failed to load configuration/i)).toBeInTheDocument(),
    );
    expect(screen.getByText("Project not found")).toBeInTheDocument();
    expect(screen.getByRole("button", { name: /retry/i })).toBeInTheDocument();
  });

  it("calls onSuccess (toast + invalidate) after successful save", async () => {
    const { toast } = await import("sonner");
    const fetchMock = vi.fn(async (input: RequestInfo | URL, init?: RequestInit) => {
      const url = (input as string);
      if (url.endsWith("/api/v1/projects/proj-1") && (init as RequestInit)?.method === "PUT") {
        return new Response(JSON.stringify(projectDetailResponse), {
          status: 200,
          headers: { "content-type": "application/json" },
        });
      }
      return new Response(JSON.stringify(projectDetailResponse), {
        status: 200,
        headers: { "content-type": "application/json" },
      });
    });
    vi.stubGlobal("fetch", fetchMock);

    renderTab({ projectId: "proj-1", slug: "alpha", active: true });

    await waitFor(() => expect(screen.getByLabelText("Slug")).toBeInTheDocument());

    const { userEvent } = await import("@testing-library/user-event");
    const user = userEvent.setup();
    await user.click(screen.getByRole("button", { name: /save/i }));

    await waitFor(() => expect(toast.success).toHaveBeenCalledWith("Configuration saved"));
  });
});
