import { render, screen, waitFor, within } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { MemoryRouter } from "react-router-dom";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { AppRoutes } from "@/App";
import { DashboardConnectionProvider } from "@/lib/dashboardConnection";
import { makeFakeSocket, type FakeSocket } from "@/test/fakeSocket";
import activityFixture from "@/test/fixtures/project_activity_page.fixture.json";
import artifactsFixture from "@/test/fixtures/project_artifacts_page.fixture.json";
import intakeFixture from "@/test/fixtures/intake_diagnostics.fixture.json";
import runDetailFixture from "@/test/fixtures/run_detail.fixture.json";
import runStreamFixture from "@/test/fixtures/run_stream_page.fixture.json";
import summaryFixture from "@/test/fixtures/project_summary.fixture.json";
import workRunsFixture from "@/test/fixtures/work_runs_page.fixture.json";

// T26.1: the screens kept from before the Case Center stay reachable from
// their deep links, with Polish labels, the soft-stop semantics and an
// unchanged stop/retry API contract (POST /api/v1/runs/:identifier/{stop,retry}).

let fakeSocket: FakeSocket = makeFakeSocket();

vi.mock("@/lib/socket", async (importOriginal) => {
  const original = await importOriginal<typeof import("@/lib/socket")>();
  return { ...original, getSocket: () => fakeSocket };
});

const PROJECT = {
  id: "proj-uuid-1",
  slug: "alpha",
  display_name: "Alfa",
  ui_color: "purple",
  linear_project_slug: "alpha-linear",
  linear_team_key: "COD",
  linear_human_review_state: "Human Review",
  github_owner: "acme",
  github_repo: "portal",
  github_base_branch: "main",
  forge_type: "github",
  forge_base_url: null,
  forge_secret: "set",
  tracker_secret: "unset",
  config_version: 3,
  config: {},
  inserted_at: "2026-09-01T00:00:00Z",
  updated_at: "2026-09-01T00:00:00Z",
};

const STATE = {
  generated_at: "2026-09-22T10:00:00Z",
  counts: { running: 0, retrying: 0, blocked: 0 },
  running: [],
  retrying: [],
  blocked: [],
  intake: intakeFixture,
};

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json" } });
}

const calls: Array<{ method: string; url: string }> = [];

beforeEach(() => {
  calls.length = 0;
  vi.stubGlobal(
    "fetch",
    vi.fn(async (input: RequestInfo | URL, init?: RequestInit) => {
      const url = String(input);
      const method = init?.method ?? "GET";
      calls.push({ method, url });
      if (method === "POST" && url.endsWith("/api/v1/runs/COD-10/stop")) return json({ status: "stopped" });
      if (method === "POST" && url.endsWith("/api/v1/runs/COD-11/retry")) return json({ status: "retrying" });
      if (url.includes("/api/v1/runs/COD-10/stream") || url.includes("/api/v1/runs/COD-11/stream")) {
        return json(runStreamFixture);
      }
      if (url.endsWith("/api/v1/runs/COD-10")) return json(runDetailFixture);
      if (url.endsWith("/api/v1/runs/COD-11")) {
        return json({ ...runDetailFixture, identifier: "COD-11", status: "retrying" });
      }
      if (url.includes("/api/v1/projects/alpha/summary")) {
        return json({ ...summaryFixture, project: { ...summaryFixture.project, display_name: "Alfa" } });
      }
      if (url.includes("/api/v1/projects/alpha/artifacts")) return json(artifactsFixture);
      if (url.includes("/api/v1/projects/alpha/activity")) return json(activityFixture);
      if (url.includes("/api/v1/work_runs")) return json(workRunsFixture);
      if (url.endsWith("/api/v1/projects/proj-uuid-1")) return json({ project: PROJECT });
      if (url.includes("/api/v1/projects")) return json({ projects: [PROJECT] });
      if (url.includes("/api/v1/state")) return json(STATE);
      return json({ error: { code: "not_found", message: "Route not found" } }, 404);
    }),
  );
});

afterEach(() => {
  vi.restoreAllMocks();
  fakeSocket = makeFakeSocket();
});

function renderAt(path: string) {
  const qc = new QueryClient({ defaultOptions: { queries: { retry: false }, mutations: { retry: false } } });
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

const main = () => within(screen.getByRole("main"));

describe("Diagnostyka i środowisko uruchomieniowe", () => {
  it("/overview is Diagnostyka with the intake metrics and a link to /runtime", async () => {
    renderAt("/overview");
    expect(await main().findByRole("heading", { level: 1, name: "Diagnostyka" })).toBeInTheDocument();
    expect(main().getByRole("link", { name: "Środowisko uruchomieniowe" })).toHaveAttribute("href", "/runtime");
    expect(await main().findByRole("region", { name: "Intake Jira" })).toBeInTheDocument();
  });

  it("/runtime keeps the sandbox and rate limits under a Polish title", async () => {
    renderAt("/runtime");
    expect(await main().findByRole("heading", { level: 1, name: "Środowisko uruchomieniowe" })).toBeInTheDocument();
    expect(main().getByRole("heading", { name: "Limity zapytań" })).toBeInTheDocument();
  });
});

describe("przebieg agenta pod stałym deep-linkiem", () => {
  it("Stop is a described soft stop and calls the unchanged stop endpoint", async () => {
    const user = userEvent.setup();
    renderAt("/projects/alpha/runs/COD-10");
    expect(await main().findByRole("heading", { level: 1, name: /COD-10/ })).toBeInTheDocument();

    await user.click(main().getByRole("button", { name: "Zatrzymaj ten przebieg" }));
    const dialog = await screen.findByRole("alertdialog");
    expect(within(dialog).getByText("Zatrzymać ten przebieg?")).toBeInTheDocument();
    expect(dialog).toHaveTextContent(/miękkie zatrzymanie/i);
    expect(dialog).toHaveTextContent(/może jeszcze dokończyć bieżącą turę/);
    expect(dialog).not.toHaveTextContent(/zabi|kill/i);

    await user.click(within(dialog).getByRole("button", { name: "Zatrzymaj przebieg" }));
    await waitFor(() =>
      expect(calls).toContainEqual({ method: "POST", url: "/api/v1/runs/COD-10/stop" }),
    );
  });

  it("Retry calls the unchanged retry endpoint", async () => {
    const user = userEvent.setup();
    renderAt("/projects/alpha/runs/COD-11");
    await user.click(await main().findByRole("button", { name: "Ponów ten przebieg teraz" }));
    await waitFor(() =>
      expect(calls).toContainEqual({ method: "POST", url: "/api/v1/runs/COD-11/retry" }),
    );
  });

  it("shows the event stream, tokens and artifacts in Polish", async () => {
    renderAt("/projects/alpha/runs/COD-10");
    expect(await main().findByRole("list", { name: "Strumień zdarzeń przebiegu" })).toBeInTheDocument();
    expect(main().getByText("Tokeny")).toBeInTheDocument();
    expect(main().getByText("Artefakty")).toBeInTheDocument();
  });
});

describe("przestrzeń projektu", () => {
  it("keeps Praca, Dowody, Aktywność and Konfiguracja reachable by ?tab=", async () => {
    renderAt("/projects/alpha");
    expect(await main().findByRole("heading", { level: 1, name: "Alfa" })).toBeInTheDocument();
    for (const name of ["Praca", "Dowody", "Aktywność", "Konfiguracja"]) {
      expect(main().getByRole("tab", { name })).toBeInTheDocument();
    }
    expect(main().getByRole("tab", { name: "Praca" })).toHaveAttribute("aria-selected", "true");
    await waitFor(() =>
      expect(main().getAllByRole("link", { name: "COD-10" })[0]).toHaveAttribute("href", "/projects/alpha/runs/COD-10"),
    );
  });

  it("?tab=evidence shows the evidence of the runs", async () => {
    renderAt("/projects/alpha?tab=evidence");
    expect(await main().findByRole("tab", { name: "Dowody" })).toHaveAttribute("aria-selected", "true");
    expect(await main().findByText("Nieprzypisane")).toBeInTheDocument();
  });

  it("?tab=activity shows the paginated log of events", async () => {
    renderAt("/projects/alpha?tab=activity");
    expect(await main().findByRole("tab", { name: "Aktywność" })).toHaveAttribute("aria-selected", "true");
    expect(await main().findByText("turn_end")).toBeInTheDocument();
    expect(main().getByRole("button", { name: "Wczytaj więcej" })).toBeInTheDocument();
  });

  it("?tab=configuration shows the project configuration form", async () => {
    renderAt("/projects/alpha?tab=configuration");
    expect(await main().findByRole("tab", { name: "Konfiguracja" })).toHaveAttribute("aria-selected", "true");
    expect(await main().findByLabelText("Slug")).toHaveValue("alpha");
    expect(main().getByRole("button", { name: "Zapisz" })).toBeInTheDocument();
  });

  it("the projects catalog links every project to its workspace and edit form", async () => {
    renderAt("/projects");
    expect(main().getByRole("heading", { level: 1, name: "Projekty" })).toBeInTheDocument();
    expect(await main().findByRole("link", { name: "Alfa" })).toHaveAttribute("href", "/projects/alpha");
    expect(main().getByRole("link", { name: "Edytuj projekt Alfa" })).toHaveAttribute("href", "/projects/proj-uuid-1/edit");
  });
});

describe("brakująca strona", () => {
  it("is a Polish 404 with a way back to the Case Center", () => {
    renderAt("/nope");
    expect(main().getByRole("heading", { level: 1, name: "Nie znaleziono strony" })).toBeInTheDocument();
    expect(main().getByRole("link", { name: "Wróć do Centrum spraw" })).toHaveAttribute("href", "/");
  });
});
