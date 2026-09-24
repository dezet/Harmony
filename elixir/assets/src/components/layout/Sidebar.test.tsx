import { render, screen, waitFor, within } from "@testing-library/react";
import { MemoryRouter } from "react-router-dom";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { describe, it, expect, vi, afterEach } from "vitest";
import { Sidebar } from "@/components/layout/Sidebar";
import { DashboardConnectionProvider } from "@/lib/dashboardConnection";
import { makeFakeSocket, type FakeSocket } from "@/test/fakeSocket";
import type { Project, ProjectColor } from "@/types/contract";

let fakeSocket: FakeSocket = makeFakeSocket();

vi.mock("@/lib/socket", async (importOriginal) => {
  const original = await importOriginal<typeof import("@/lib/socket")>();
  return { ...original, getSocket: () => fakeSocket };
});

afterEach(() => {
  vi.restoreAllMocks();
  fakeSocket = makeFakeSocket();
});

function project(id: string, slug: string, displayName: string | null, color: ProjectColor): Project {
  return {
    id,
    slug,
    display_name: displayName,
    ui_color: color,
    linear_project_slug: null,
    linear_team_key: null,
    linear_human_review_state: null,
    github_owner: "acme",
    github_repo: slug,
    github_base_branch: "main",
    forge_type: "github",
    forge_base_url: null,
    forge_secret: "unset",
    tracker_secret: "unset",
    config_version: 1,
    config: {},
    inserted_at: "2026-09-01T00:00:00Z",
    updated_at: "2026-09-01T00:00:00Z",
  };
}

const PROJECTS = [
  project("p1", "portal", "Portal klienta", "purple"),
  project("p2", "finanse", "Finanse", "gold"),
  project("p3", "hr", null, "teal"),
];

function json(body: unknown): Response {
  return new Response(JSON.stringify(body), {
    status: 200,
    headers: { "content-type": "application/json" },
  });
}

function stubApi(
  projectCounts: Array<{ project_id: string; total: number }>,
  projects = PROJECTS,
  decision = 0,
) {
  const fetchMock = vi.fn(async (input: RequestInfo | URL) => {
    const url = String(input);
    if (url.includes("/api/v1/projects")) return json({ projects });
    if (url.includes("/api/v1/cases")) {
      return json({
        items: [],
        meta: { next_cursor: null, total: 0, page_size: 1 },
        counts: { all: decision, decision, analysis: 0, done: 0, detected: 0 },
        project_counts: projectCounts,
      });
    }
    return json({ generated_at: "2026-09-24T00:00:00Z" });
  });
  vi.stubGlobal("fetch", fetchMock);
  return fetchMock;
}

function renderSidebar(path = "/") {
  const qc = new QueryClient({ defaultOptions: { queries: { retry: false } } });
  return render(
    <QueryClientProvider client={qc}>
      <DashboardConnectionProvider initialStatus="live">
        <MemoryRouter initialEntries={[path]}>
          <Sidebar />
        </MemoryRouter>
      </DashboardConnectionProvider>
    </QueryClientProvider>,
  );
}

function projectLink(name: RegExp) {
  return within(screen.getByRole("navigation", { name: "Projekty" })).getByRole("link", { name });
}

describe("Sidebar", () => {
  it("lists the Polish sections in the order of layout A", async () => {
    stubApi([]);
    renderSidebar();

    const main = screen.getByRole("navigation", { name: "Główna" });
    expect(within(main).getAllByRole("link").map((link) => link.textContent?.trim())).toEqual([
      "Centrum spraw",
      "Automatyzacje",
      "Integracje",
    ]);
    expect(within(main).getByRole("link", { name: "Centrum spraw" })).toHaveAttribute("href", "/");
    expect(within(main).getByRole("link", { name: "Automatyzacje" })).toHaveAttribute(
      "href",
      "/automations",
    );
    expect(within(main).getByRole("link", { name: "Integracje" })).toHaveAttribute(
      "href",
      "/integrations",
    );

    await waitFor(() => expect(projectLink(/Finanse/)).toBeInTheDocument());
    const projects = screen.getByRole("navigation", { name: "Projekty" });
    expect(within(projects).getAllByRole("link").map((l) => l.getAttribute("href"))).toEqual([
      "/?project=portal",
      "/?project=finanse",
      "/?project=hr",
      "/projects",
    ]);
    expect(within(projects).getByRole("link", { name: "Wszystkie projekty" })).toHaveAttribute(
      "href",
      "/projects",
    );
    expect(screen.getByRole("heading", { name: "Projekty" })).toBeInTheDocument();
    expect(screen.getByRole("link", { name: "Diagnostyka" })).toHaveAttribute("href", "/overview");
  });

  it("shows the number of cases awaiting a decision next to Centrum spraw", async () => {
    stubApi([], PROJECTS, 4);
    renderSidebar();

    const main = screen.getByRole("navigation", { name: "Główna" });
    await waitFor(() =>
      expect(within(main).getByRole("link", { name: /^Centrum spraw/ })).toHaveAccessibleName(
        "Centrum spraw, 4 do decyzji",
      ),
    );
  });

  it("shows project display names and falls back to the slug", async () => {
    stubApi([]);
    renderSidebar();

    await waitFor(() => expect(projectLink(/Portal klienta/)).toBeInTheDocument());
    expect(projectLink(/^hr/)).toBeInTheDocument();
  });

  it("marks the project selected in the case filter with aria-current", async () => {
    stubApi([]);
    renderSidebar("/?project=finanse");

    await waitFor(() => expect(projectLink(/Finanse/)).toHaveAttribute("aria-current", "page"));
    expect(projectLink(/Portal klienta/)).not.toHaveAttribute("aria-current");
    expect(screen.getByRole("link", { name: "Wszystkie projekty" })).not.toHaveAttribute(
      "aria-current",
    );
  });

  it("marks Wszystkie projekty active on the project catalog", async () => {
    stubApi([]);
    renderSidebar("/projects");

    await waitFor(() => expect(projectLink(/Finanse/)).toBeInTheDocument());
    expect(screen.getByRole("link", { name: "Wszystkie projekty" })).toHaveAttribute(
      "aria-current",
      "page",
    );
    expect(projectLink(/Finanse/)).not.toHaveAttribute("aria-current");
  });

  it("badges show all projected cases, keep zeros and cap the text at 999+", async () => {
    stubApi([
      { project_id: "p1", total: 1234 },
      { project_id: "p2", total: 0 },
      { project_id: "p3", total: 3 },
    ]);
    renderSidebar();

    await waitFor(() => expect(projectLink(/Portal klienta/)).toHaveTextContent("999+"));
    expect(projectLink(/Portal klienta/)).toHaveAccessibleName("Portal klienta, 1234 sprawy");
    expect(projectLink(/Finanse/)).toHaveTextContent("0");
    expect(projectLink(/Finanse/)).toHaveAccessibleName("Finanse, 0 spraw");
    expect(projectLink(/^hr/)).toHaveAccessibleName("hr, 3 sprawy");
  });

  it("requests the case projection totals, not live run counts", async () => {
    const fetchMock = stubApi([{ project_id: "p1", total: 1 }]);
    renderSidebar();

    await waitFor(() =>
      expect(projectLink(/Portal klienta/)).toHaveAccessibleName("Portal klienta, 1 sprawa"),
    );
    const urls = fetchMock.mock.calls.map(([input]) => String(input));
    expect(urls.some((url) => url.includes("/api/v1/cases"))).toBe(true);
    expect(urls.some((url) => url.includes("/api/v1/state"))).toBe(false);
  });

  it("uses the project color only as identity, never a health color", async () => {
    stubApi([]);
    renderSidebar();

    await waitFor(() => expect(projectLink(/Finanse/)).toBeInTheDocument());
    const colors = [/Portal klienta/, /Finanse/, /^hr/].map((name) =>
      projectLink(name).style.getPropertyValue("--project-color"),
    );
    expect(colors).toEqual([
      "var(--project-purple)",
      "var(--project-gold)",
      "var(--project-teal)",
    ]);
    const projectsHtml = screen.getByRole("navigation", { name: "Projekty" }).innerHTML;
    expect(projectsHtml).not.toMatch(/emerald|amber|red-500|healthy|blocked|retrying/);
  });

  it("styles hover and keyboard focus with the project color and a 200 ms ease", async () => {
    stubApi([{ project_id: "p2", total: 1 }]);
    renderSidebar();

    await waitFor(() => expect(projectLink(/Finanse/)).toHaveTextContent("1"));
    const row = projectLink(/Finanse/);
    for (const cls of [
      "hover:bg-(--project-color)",
      "hover:text-white",
      "focus-visible:bg-(--project-color)",
      "focus-visible:text-white",
      "duration-200",
      "ease-[ease]",
      "motion-reduce:transition-none",
    ]) {
      expect(row).toHaveClass(cls);
    }

    const dot = row.querySelector("[data-slot=project-dot]");
    expect(dot).toHaveClass(
      "size-[7px]",
      "group-hover/project:bg-white",
      "group-focus-visible/project:bg-white",
      "group-hover/project:[transform:scale(1.15)]",
      "group-focus-visible/project:[transform:scale(1.15)]",
      "motion-reduce:transition-none",
    );

    const badge = row.querySelector("[data-slot=project-count]");
    expect(badge).toHaveClass(
      "min-w-[23px]",
      "h-[21px]",
      "px-[6px]",
      "rounded-[6px]",
      "text-[10px]",
      "font-semibold",
      "tabular-nums",
      "group-hover/project:bg-white/15",
      "group-hover/project:text-white",
      "group-focus-visible/project:bg-white/15",
      "group-focus-visible/project:text-white",
    );
  });

  it("shows the team space and the real connection state without a demo profile", async () => {
    stubApi([]);
    renderSidebar();

    expect(screen.getByText("Przestrzeń zespołu")).toBeInTheDocument();
    expect(screen.getByText("Połączono")).toBeInTheDocument();
    expect(screen.getByRole("button", { name: /tryb ciemny/i })).toBeInTheDocument();
    for (const demo of [/Daniel/, /Engineering Team/, /PODGLĄD/i, /Prototyp/, /Właściciel/]) {
      expect(screen.queryByText(demo)).not.toBeInTheDocument();
    }
  });

  it("shows an empty state when no project exists", async () => {
    stubApi([], []);
    renderSidebar();

    await waitFor(() => expect(screen.getByText("Brak projektów")).toBeInTheDocument());
    expect(screen.getByRole("link", { name: "Wszystkie projekty" })).toBeInTheDocument();
  });
});
