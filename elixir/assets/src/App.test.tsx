import { render, screen, waitFor, within } from "@testing-library/react";
import { MemoryRouter } from "react-router-dom";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import { AppRoutes } from "@/App";
import { DashboardConnectionProvider } from "@/lib/dashboardConnection";
import { makeFakeSocket, type FakeSocket } from "@/test/fakeSocket";
import caseDetailFixture from "@/test/fixtures/case_detail.fixture.json";

let fakeSocket: FakeSocket = makeFakeSocket();

vi.mock("@/lib/socket", async (importOriginal) => {
  const original = await importOriginal<typeof import("@/lib/socket")>();
  return { ...original, getSocket: () => fakeSocket };
});

const PROJECTS = [
  {
    id: "p2",
    slug: "finanse",
    display_name: "Finanse",
    ui_color: "gold",
    linear_project_slug: null,
    linear_team_key: null,
    linear_human_review_state: null,
    github_owner: "acme",
    github_repo: "finanse",
    github_base_branch: "main",
    forge_type: "github",
    forge_base_url: null,
    forge_secret: "unset",
    tracker_secret: "unset",
    config_version: 1,
    config: {},
    inserted_at: "2026-09-01T00:00:00Z",
    updated_at: "2026-09-01T00:00:00Z",
  },
];

function json(body: unknown): Response {
  return new Response(JSON.stringify(body), {
    status: 200,
    headers: { "content-type": "application/json" },
  });
}

beforeEach(() => {
  vi.stubGlobal(
    "fetch",
    vi.fn(async (input: RequestInfo | URL) => {
      const url = String(input);
      if (url.includes("/api/v1/projects")) return json({ projects: PROJECTS });
      if (url.includes("/api/v1/automations")) return json({ items: [], meta: { next_cursor: null, page_size: 100 } });
      if (url.endsWith(`/api/v1/cases/${caseDetailFixture.case.ref}`)) return json(caseDetailFixture);
      if (url.includes(`/api/v1/cases/${caseDetailFixture.case.ref}/events`)) {
        return json({ items: [], meta: { next_cursor: null, page_size: 50 } });
      }
      if (url.includes("/api/v1/cases")) {
        return json({
          items: [],
          meta: { next_cursor: null, total: 0, page_size: 1 },
          counts: { all: 0, decision: 0, analysis: 0, done: 0, detected: 0 },
          project_counts: [{ project_id: "p2", total: 0 }],
        });
      }
      return json({
        generated_at: "2026-06-02T00:00:00Z",
        counts: { running: 0, retrying: 0, blocked: 0 },
        running: [],
        retrying: [],
        blocked: [],
      });
    }),
  );
});
afterEach(() => {
  vi.restoreAllMocks();
  fakeSocket = makeFakeSocket();
});

function renderAt(path: string) {
  const qc = new QueryClient({ defaultOptions: { queries: { retry: false } } });
  return render(
    <QueryClientProvider client={qc}>
      <DashboardConnectionProvider>
        <MemoryRouter initialEntries={[path]}>
          <AppRoutes />
        </MemoryRouter>
      </DashboardConnectionProvider>
    </QueryClientProvider>,
  );
}

function heading() {
  return within(screen.getByRole("main")).getByRole("heading", { level: 1 });
}

describe("AppRoutes", () => {
  it("opens the Case Center at / inside the A shell", async () => {
    renderAt("/");
    expect(screen.getByRole("navigation", { name: "Główna" })).toBeInTheDocument();
    expect(screen.getByRole("navigation", { name: "Ścieżka" })).toBeInTheDocument();
    expect(heading()).toHaveTextContent("Centrum spraw");
    expect(
      within(screen.getByRole("navigation", { name: "Główna" })).getByRole("link", {
        name: "Centrum spraw",
      }),
    ).toHaveAttribute("aria-current", "page");
  });

  it("shows the selected project and keeps its agent workspace reachable", async () => {
    renderAt("/?project=finanse");
    await waitFor(() => expect(heading()).toHaveTextContent("Finanse"));
    expect(
      within(screen.getByRole("main")).getByRole("link", { name: "Praca agentów i ustawienia" }),
    ).toHaveAttribute("href", "/projects/finanse");
  });

  it("reports an unknown project instead of silently showing all cases", async () => {
    renderAt("/?project=brak");
    await waitFor(() => expect(heading()).toHaveTextContent("Nie znaleziono projektu"));
    expect(
      within(screen.getByRole("main")).getByRole("link", { name: "Wszystkie projekty" }),
    ).toHaveAttribute("href", "/projects");
  });

  it("keeps the technical overview at /overview", async () => {
    renderAt("/overview");
    await waitFor(() =>
      expect(screen.getByRole("heading", { name: "Overview" })).toBeInTheDocument(),
    );
    expect(screen.getByRole("link", { name: "Diagnostyka" })).toHaveAttribute(
      "aria-current",
      "page",
    );
  });

  it("reserves the Automatyzacje and Integracje sections without sample data", () => {
    renderAt("/automations");
    expect(heading()).toHaveTextContent("Automatyzacje");
    expect(screen.queryByText(/Jira · Electrum|Portal klienta|OPS-142/)).not.toBeInTheDocument();
  });

  it("serves Integracje at /integrations", () => {
    renderAt("/integrations");
    expect(heading()).toHaveTextContent("Integracje");
  });

  it("keeps the run deep-link and the project routes", () => {
    renderAt("/projects/alpha/runs/COD-1");
    const trail = screen.getByRole("navigation", { name: "Ścieżka" });
    expect(within(trail).getByText("COD-1")).toHaveAttribute("aria-current", "page");
    expect(within(screen.getByRole("main")).queryByText(/Nie znaleziono/)).not.toBeInTheDocument();
  });

  it("serves the standalone case deep link at /cases/:ref", async () => {
    renderAt(`/cases/${caseDetailFixture.case.ref}`);
    await waitFor(() => expect(heading()).toHaveTextContent("Eksport raportu kończy się błędem 504"));
    const trail = screen.getByRole("navigation", { name: "Ścieżka" });
    expect(within(trail).getByText("Szczegóły sprawy")).toHaveAttribute("aria-current", "page");
  });

  it("shows the projects page at /projects", () => {
    renderAt("/projects");
    expect(screen.getByRole("heading", { name: /projects/i })).toBeInTheDocument();
  });

  it("shows a not-found page for unknown routes", () => {
    renderAt("/nope");
    expect(within(screen.getByRole("main")).getByText(/not found/i)).toBeInTheDocument();
  });
});
