import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { act, render, screen, waitFor, within } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { createMemoryRouter, RouterProvider } from "react-router-dom";
import casesPageFixture from "@/test/fixtures/cases_page.fixture.json";
import ruleFixture from "@/test/fixtures/automation_rule.fixture.json";
import { makeFakeSocket, type FakeSocket } from "@/test/fakeSocket";
import { CasesPage } from "@/features/cases/CasesPage";
import { CASE_VIEW_STORAGE_KEY } from "@/features/cases/useCaseFilters";
import type { AutomationRule, CaseSummary, CasesPage as CasesPageBody, Project } from "@/types/contract";

let fakeSocket: FakeSocket;

vi.mock("@/lib/socket", async (importOriginal) => {
  const original = await importOriginal<typeof import("@/lib/socket")>();
  return { ...original, getSocket: () => fakeSocket };
});

const fixture = casesPageFixture as CasesPageBody;
const PORTAL_ID = "11111111-1111-4111-8111-111111111111";

function project(id: string, slug: string, name: string, color: Project["ui_color"]): Project {
  return {
    id,
    slug,
    display_name: name,
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
  project(PORTAL_ID, "portal-klienta", "Portal klienta", "purple"),
  project("22222222-2222-4222-8222-222222222222", "finanse", "Finanse", "gold"),
];

const activeRule: AutomationRule = { ...(ruleFixture as AutomationRule), enabled: true };
const pausedRule: AutomationRule = { ...(ruleFixture as AutomationRule), enabled: false };

const FILTER_COLUMNS: Record<string, CaseSummary["column"]> = {
  decision: "decision",
  analysis: "analyzing",
  done: "handed_off",
};

// Server-side filtering of the fixture, so Back/Forward results can be told apart.
function pageFor(params: URLSearchParams): CasesPageBody {
  const column = FILTER_COLUMNS[params.get("filter") ?? ""];
  const slug = params.get("project");
  const q = (params.get("q") ?? "").toLowerCase();
  const items = fixture.items.filter(
    (item) =>
      (!column || item.column === column) &&
      (!slug || item.project.slug === slug) &&
      (!q || `${item.title} ${item.jira?.key ?? ""} ${item.linear?.identifier ?? ""}`.toLowerCase().includes(q)),
  );
  return { ...fixture, items, meta: { ...fixture.meta, total: items.length } };
}

function manyItems(from: number, to: number): CaseSummary[] {
  return Array.from({ length: to - from + 1 }, (_, i) => {
    const n = from + i;
    return { ...fixture.items[0], ref: `jira_${n}`, title: `Sprawa numer ${n}` };
  });
}

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json" } });
}

function apiError(status: number, code: string): Response {
  return json({ error: { code, message: code, fields: {} } }, status);
}

type Reply = Response | Promise<Response>;

interface Call {
  method: string;
  path: string;
  params: URLSearchParams;
  init: RequestInit | undefined;
}

let calls: Call[];
let onCases: (params: URLSearchParams) => Reply;
let onAutomations: (params: URLSearchParams) => Reply;
let onCheck: (body: unknown) => Reply;
let onRefresh: () => Reply;

function deferred() {
  let resolve!: (response: Response) => void;
  const promise = new Promise<Response>((r) => {
    resolve = r;
  });
  return { promise, resolve };
}

const casesCalls = () => calls.filter((call) => call.path === "/api/v1/cases");

beforeEach(() => {
  fakeSocket = makeFakeSocket();
  window.localStorage.clear();
  calls = [];
  onCases = (params) => json(pageFor(params));
  onAutomations = () => json({ items: [activeRule], meta: { next_cursor: null, page_size: 100 } });
  onCheck = () => json({ accepted_rule_ids: [activeRule.id], skipped: [] }, 202);
  onRefresh = () => json({ queued: true, coalesced: false, requested_at: "2026-09-22T10:00:00Z", operations: ["poll"] }, 202);

  vi.stubGlobal(
    "fetch",
    vi.fn(async (input: RequestInfo | URL, init?: RequestInit) => {
      const url = new URL(String(input), "http://localhost");
      const method = init?.method ?? "GET";
      calls.push({ method, path: url.pathname, params: url.searchParams, init });

      switch (url.pathname) {
        case "/api/v1/projects":
          return json({ projects: PROJECTS });
        case "/api/v1/cases":
          return onCases(url.searchParams);
        case "/api/v1/automations":
          return onAutomations(url.searchParams);
        case "/api/v1/csrf":
          return json({ csrf_token: "csrf-test-token" });
        case "/api/v1/automations/check":
          return onCheck(JSON.parse(String(init?.body ?? "{}")));
        case "/api/v1/refresh":
          return onRefresh();
        default:
          return apiError(404, "not_found");
      }
    }),
  );
});

afterEach(() => {
  vi.unstubAllGlobals();
  vi.restoreAllMocks();
});

function renderPage(url: string) {
  const qc = new QueryClient({ defaultOptions: { queries: { retry: false } } });
  const router = createMemoryRouter(
    [
      { path: "/", element: <CasesPage /> },
      { path: "/automations", element: <p>Ekran automatyzacji</p> },
      { path: "/projects", element: <p>Katalog projektów</p> },
    ],
    { initialEntries: [url] },
  );
  render(
    <QueryClientProvider client={qc}>
      <RouterProvider router={router} />
    </QueryClientProvider>,
  );
  return { router, search: () => new URLSearchParams(router.state.location.search) };
}

const listRegion = () => screen.getByRole("region", { name: "Lista spraw" });
const listTitles = () =>
  within(listRegion())
    .queryAllByRole("listitem")
    .map((item) => item.querySelector("[data-slot=case-title]")?.textContent);
const statsRegion = () => screen.getByRole("region", { name: "Podsumowanie spraw" });
const checkStatus = () => screen.getByRole("status", { name: "Wynik sprawdzenia" });
const exactText = (text: string) => (_: string, element: Element | null) => element?.textContent === text;

async function waitForList() {
  await waitFor(() => expect(within(listRegion()).getAllByRole("listitem").length).toBeGreaterThan(0));
}

describe("T21.1 URL state", () => {
  it("restores project, search and filter from the URL", async () => {
    renderPage("/?project=portal-klienta&filter=decision&q=OPS");

    await waitFor(() => expect(listTitles()).toEqual(["Eksport raportu kończy się błędem 504"]));
    const listCall = casesCalls().find((call) => call.params.get("q") === "OPS");
    expect(listCall?.params.toString()).toBe("project=portal-klienta&filter=decision&q=OPS");
    expect(screen.getByRole("button", { name: /^Do decyzji/ })).toHaveAttribute("aria-pressed", "true");
    expect(screen.getByRole("searchbox", { name: "Szukaj spraw" })).toHaveValue("OPS");
    expect(screen.getByRole("heading", { level: 1 })).toHaveTextContent("Portal klienta");
    expect(screen.getByRole("link", { name: "Praca agentów i ustawienia" })).toHaveAttribute(
      "href",
      "/projects/portal-klienta",
    );
  });

  it("restores the earlier filter result on Back and the later one on Forward", async () => {
    const user = userEvent.setup();
    const { router, search } = renderPage("/?project=portal-klienta");
    await waitFor(() => expect(listTitles()).toHaveLength(5));

    await user.click(screen.getByRole("button", { name: /^W analizie/ }));
    await waitFor(() =>
      expect(listTitles()).toEqual(["Brak wiadomości po zresetowaniu hasła", "Wdrożenie limitu czasu raportu"]),
    );
    expect(search().get("filter")).toBe("analysis");

    await act(() => router.navigate(-1));
    await waitFor(() => expect(listTitles()).toHaveLength(5));
    expect(screen.getByRole("button", { name: /^Wszystkie/ })).toHaveAttribute("aria-pressed", "true");

    await act(() => router.navigate(1));
    await waitFor(() => expect(listTitles()).toHaveLength(2));
    expect(screen.getByRole("button", { name: /^W analizie/ })).toHaveAttribute("aria-pressed", "true");
  });

  it("restores a search on Back and Forward", async () => {
    const user = userEvent.setup();
    const { router } = renderPage("/?q=FIN-87");
    await waitFor(() => expect(listTitles()).toEqual(["Różnica w sumie faktur po imporcie"]));

    await user.clear(screen.getByRole("searchbox", { name: "Szukaj spraw" }));
    await waitFor(() => expect(listTitles()).toHaveLength(fixture.items.length));

    await act(() => router.navigate(-1));
    await waitFor(() => expect(listTitles()).toEqual(["Różnica w sumie faktur po imporcie"]));
    expect(screen.getByRole("searchbox", { name: "Szukaj spraw" })).toHaveValue("FIN-87");

    await act(() => router.navigate(1));
    await waitFor(() => expect(listTitles()).toHaveLength(fixture.items.length));
    expect(screen.getByRole("searchbox", { name: "Szukaj spraw" })).toHaveValue("");
  });

  it("selects a case in the URL and drops a selection that left the result", async () => {
    const user = userEvent.setup();
    const { search } = renderPage("/?project=portal-klienta");
    await waitForList();

    const item = screen.getByRole("button", { name: /Eksport raportu kończy się błędem 504/ });
    await user.click(item);
    expect(search().get("case")).toBe("jira_aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa");
    expect(screen.getByRole("button", { name: /Eksport raportu kończy się błędem 504/ })).toHaveAttribute(
      "aria-pressed",
      "true",
    );

    await user.click(screen.getByRole("button", { name: /^W analizie/ }));
    await waitFor(() => expect(search().has("case")).toBe(false));
    expect(search().get("filter")).toBe("analysis");
  });
});

describe("T21.2 default list", () => {
  it("shows 25 cases and loads the next page with the cursor on „Pokaż więcej”", async () => {
    const user = userEvent.setup();
    onCases = (params) =>
      json({
        ...fixture,
        items: params.get("cursor") ? manyItems(26, 30) : manyItems(1, 25),
        meta: { next_cursor: params.get("cursor") ? null : "cursor-2", total: 30, page_size: 25 },
      });
    renderPage("/?project=portal-klienta");

    await waitFor(() => expect(listTitles()).toHaveLength(25));
    await user.click(screen.getByRole("button", { name: "Pokaż więcej" }));
    await waitFor(() => expect(listTitles()).toHaveLength(30));

    const next = casesCalls().find((call) => call.params.has("cursor"));
    expect(next?.params.toString()).toBe("project=portal-klienta&cursor=cursor-2");
    expect(screen.queryByRole("button", { name: "Pokaż więcej" })).not.toBeInTheDocument();
  });

  it("reads data only through the intake API hooks", async () => {
    renderPage("/");
    await waitForList();
    const paths = new Set(calls.map((call) => call.path));
    expect([...paths].sort()).toEqual(["/api/v1/automations", "/api/v1/cases", "/api/v1/projects"]);
    expect(screen.queryByText(/Daniel|PODGLĄD|Prototyp|Dane przykładowe/)).not.toBeInTheDocument();
  });
});

describe("T21.3 aggregates", () => {
  it("takes stats from the project scope and filter badges from project+q, never from items.length", async () => {
    onCases = (params) =>
      params.has("q")
        ? json({
            ...fixture,
            items: fixture.items.slice(0, 2),
            meta: { next_cursor: "more", total: 3, page_size: 25 },
            counts: { all: 7, decision: 3, analysis: 2, done: 1, detected: 1 },
          })
        : json({
            ...fixture,
            meta: { next_cursor: "more", total: 40, page_size: 25 },
            counts: { all: 40, decision: 11, analysis: 5, done: 20, detected: 4 },
          });
    renderPage("/?project=portal-klienta&filter=decision&q=raport");

    await waitFor(() => expect(within(statsRegion()).getByText(exactText("11 do Twojej decyzji"))).toBeInTheDocument());
    expect(within(statsRegion()).getByText(exactText("5 analiza w toku"))).toBeInTheDocument();
    expect(within(statsRegion()).getByText(exactText("4 w kolejce"))).toBeInTheDocument();

    const statsCall = casesCalls().find((call) => !call.params.has("q"));
    expect(statsCall?.params.toString()).toBe("project=portal-klienta");

    await waitFor(() => expect(screen.getByRole("button", { name: "Wszystkie 7" })).toBeInTheDocument());
    expect(screen.getByRole("button", { name: "Do decyzji 3" })).toBeInTheDocument();
    expect(screen.getByRole("button", { name: "W analizie 2" })).toBeInTheDocument();
    expect(screen.getByRole("button", { name: "Zakończone 1" })).toBeInTheDocument();
    expect(within(listRegion()).getByText("3 sprawy")).toBeInTheDocument();
    expect(listTitles()).toHaveLength(2);
  });
});

describe("T21.4 search", () => {
  it("debounces, aborts the superseded request and shows the newest result", async () => {
    const user = userEvent.setup();
    const pending = new Map<string, ReturnType<typeof deferred>>();
    onCases = (params) => {
      const q = params.get("q");
      if (!q) return json(pageFor(params));
      const reply = deferred();
      pending.set(q, reply);
      return reply.promise;
    };
    const { search } = renderPage("/");
    await waitForList();

    const box = screen.getByRole("searchbox", { name: "Szukaj spraw" });
    await user.type(box, "OPS");
    expect(casesCalls().some((call) => call.params.has("q"))).toBe(false);

    await waitFor(() => expect(pending.has("OPS")).toBe(true));
    const first = casesCalls().find((call) => call.params.get("q") === "OPS");
    expect(search().get("q")).toBe("OPS");

    await user.type(box, "-142");
    await waitFor(() => expect(pending.has("OPS-142")).toBe(true));
    expect(first?.init?.signal?.aborted).toBe(true);
    expect(casesCalls().filter((call) => call.params.has("q")).map((call) => call.params.get("q"))).toEqual([
      "OPS",
      "OPS-142",
    ]);

    await act(async () => pending.get("OPS-142")?.resolve(json(pageFor(new URLSearchParams("q=OPS-142")))));
    await waitFor(() => expect(listTitles()).toEqual(["Eksport raportu kończy się błędem 504"]));
  });

  it("starts from the first page after the filter changes", async () => {
    const user = userEvent.setup();
    onCases = (params) =>
      json({
        ...pageFor(params),
        items: params.get("cursor") ? manyItems(26, 27) : manyItems(1, 25),
        meta: { next_cursor: params.get("cursor") ? null : "cursor-2", total: 27, page_size: 25 },
      });
    renderPage("/");
    await waitFor(() => expect(listTitles()).toHaveLength(25));
    await user.click(screen.getByRole("button", { name: "Pokaż więcej" }));
    await waitFor(() => expect(listTitles()).toHaveLength(27));

    await user.click(screen.getByRole("button", { name: /^Do decyzji/ }));
    await waitFor(() => expect(casesCalls().some((call) => call.params.get("filter") === "decision")).toBe(true));
    const filtered = casesCalls().filter((call) => call.params.get("filter") === "decision");
    expect(filtered.every((call) => !call.params.has("cursor"))).toBe(true);
    await waitFor(() => expect(listTitles()).toHaveLength(25));
  });

  it("shows an empty result with a way back", async () => {
    const user = userEvent.setup();
    const { search } = renderPage("/?q=nieistniejace&filter=done");
    await waitFor(() => expect(screen.getByText("Nie ma spraw pasujących do filtrów.")).toBeInTheDocument());

    await user.click(screen.getByRole("button", { name: "Wyczyść filtry" }));
    expect(search().has("q")).toBe(false);
    expect(search().has("filter")).toBe(false);
    await waitFor(() => expect(listTitles()).toHaveLength(fixture.items.length));
    expect(screen.getByRole("searchbox", { name: "Szukaj spraw" })).toHaveValue("");
  });
});

describe("T21.5 loading, error, offline and no rules", () => {
  it("shows a loading state and then a recoverable error instead of an endless spinner", async () => {
    const user = userEvent.setup();
    const first = deferred();
    onCases = () => first.promise;
    renderPage("/");

    expect(within(listRegion()).getByRole("status")).toHaveTextContent("Wczytywanie spraw…");
    expect(listRegion()).toHaveAttribute("aria-busy", "true");

    await act(async () => first.resolve(apiError(500, "internal_error")));
    const alert = await within(listRegion()).findByRole("alert");
    expect(alert).toHaveTextContent("Nie udało się wczytać spraw.");

    onCases = (params) => json(pageFor(params));
    await user.click(within(alert).getByRole("button", { name: "Spróbuj ponownie" }));
    await waitFor(() => expect(listTitles()).toHaveLength(fixture.items.length));
    expect(listRegion()).toHaveAttribute("aria-busy", "false");
  });

  it("reports an unknown project instead of showing every case", async () => {
    onCases = () => apiError(404, "not_found");
    renderPage("/?project=brak");
    await waitFor(() => expect(screen.getByRole("heading", { level: 1 })).toHaveTextContent("Nie znaleziono projektu"));
    expect(screen.getByRole("link", { name: "Wszystkie projekty" })).toHaveAttribute("href", "/projects");
    expect(screen.queryByRole("region", { name: "Lista spraw" })).not.toBeInTheDocument();
  });

  it("keeps the last data with a warning and disables mutations while offline", async () => {
    renderPage("/");
    await waitForList();
    const onLine = vi.spyOn(window.navigator, "onLine", "get").mockReturnValue(false);
    try {
      act(() => {
        window.dispatchEvent(new Event("offline"));
      });
      expect(await screen.findByText(/Brak połączenia z serwerem/)).toBeInTheDocument();
      expect(listTitles()).toHaveLength(fixture.items.length);
      expect(screen.getByRole("button", { name: "Sprawdź teraz" })).toBeDisabled();
    } finally {
      onLine.mockRestore();
      act(() => {
        window.dispatchEvent(new Event("online"));
      });
    }
    await waitFor(() => expect(screen.getByRole("button", { name: "Sprawdź teraz" })).toBeEnabled());
  });

  it("designs the state without active Jira rules", async () => {
    onAutomations = () => json({ items: [pausedRule], meta: { next_cursor: null, page_size: 100 } });
    onCases = () =>
      json({
        ...fixture,
        items: [],
        meta: { next_cursor: null, total: 0, page_size: 25 },
        counts: { all: 0, decision: 0, analysis: 0, done: 0, detected: 0 },
      });
    renderPage("/?project=portal-klienta");

    await waitFor(() => expect(within(statsRegion()).getByText("Brak aktywnych reguł")).toBeInTheDocument());
    expect(within(listRegion()).getByText("Brak aktywnych reguł Jira")).toBeInTheDocument();
    expect(within(listRegion()).getByRole("link", { name: "Skonfiguruj reguły" })).toHaveAttribute(
      "href",
      "/automations",
    );
    const rulesCall = calls.find((call) => call.path === "/api/v1/automations");
    expect(rulesCall?.params.get("project")).toBe(PORTAL_ID);
  });

  it("shows the backend schedule of active rules and a failed rule read as text", async () => {
    const now = Date.now();
    onAutomations = () =>
      json({
        items: [
          {
            ...activeRule,
            next_poll_at: new Date(now + 5 * 60_000 - 2_000).toISOString(),
            last_success_at: new Date(now - 60_000).toISOString(),
          },
          pausedRule,
        ],
        meta: { next_cursor: null, page_size: 100 },
      });
    renderPage("/");
    await waitFor(() => expect(within(statsRegion()).getByText(/Kolejne sprawdzenie za 5 min/)).toBeInTheDocument());
    expect(within(statsRegion()).getByText(/Ostatnie sprawdzenie/)).toBeInTheDocument();
  });

  it("does not spin forever when the rule state cannot be read", async () => {
    onAutomations = () => apiError(500, "internal_error");
    renderPage("/");
    await waitFor(() => expect(within(statsRegion()).getByText("Stan reguł jest niedostępny")).toBeInTheDocument());
  });
});

describe("T21.6 „Sprawdź teraz”", () => {
  it("shows pending, then queued — never a finished scan", async () => {
    const user = userEvent.setup();
    const reply = deferred();
    onCheck = () => reply.promise;
    renderPage("/?project=portal-klienta");
    await waitForList();

    await user.click(screen.getByRole("button", { name: "Sprawdź teraz" }));
    const pendingButton = await screen.findByRole("button", { name: "Kolejkowanie…" });
    expect(pendingButton).toBeDisabled();

    const post = calls.find((call) => call.path === "/api/v1/automations/check");
    expect(post?.method).toBe("POST");
    expect(JSON.parse(String(post?.init?.body))).toEqual({ project: PORTAL_ID });
    expect(new Headers(post?.init?.headers).get("x-csrf-token")).toBe("csrf-test-token");

    await act(async () =>
      reply.resolve(json({ accepted_rule_ids: [activeRule.id, "rule-2"], skipped: [] }, 202)),
    );
    await waitFor(() => expect(checkStatus()).toHaveTextContent("Zakolejkowano sprawdzenie 2 reguł Jira."));
    expect(checkStatus()).toHaveAttribute("aria-live", "polite");
    expect(checkStatus()).not.toHaveTextContent(/zakończono|zakończony|zsynchronizowano|sukces/i);
    expect(calls.some((call) => call.path === "/api/v1/refresh" && call.method === "POST")).toBe(true);
    expect(screen.getByRole("button", { name: "Sprawdź teraz" })).toBeEnabled();
  });

  it("explains a 409 without claiming the check was queued", async () => {
    const user = userEvent.setup();
    onCheck = () => apiError(409, "intake_disabled");
    renderPage("/");
    await waitForList();

    await user.click(screen.getByRole("button", { name: "Sprawdź teraz" }));
    await waitFor(() => expect(checkStatus()).toHaveTextContent("Pobieranie zgłoszeń z Jira jest wyłączone"));
    expect(checkStatus()).not.toHaveTextContent("Zakolejkowano");
  });

  it("explains a 503 without claiming the check was queued", async () => {
    const user = userEvent.setup();
    onCheck = () => apiError(503, "scheduler_unavailable");
    renderPage("/");
    await waitForList();

    await user.click(screen.getByRole("button", { name: "Sprawdź teraz" }));
    await waitFor(() => expect(checkStatus()).toHaveTextContent("Harmonogram sprawdzeń jest niedostępny"));
    expect(checkStatus()).not.toHaveTextContent("Zakolejkowano");
  });

  it("reports skipped rules when nothing was queued", async () => {
    const user = userEvent.setup();
    onCheck = () => json({ accepted_rule_ids: [], skipped: [{ rule_id: activeRule.id, code: "scan_in_progress" }] }, 202);
    renderPage("/");
    await waitForList();

    await user.click(screen.getByRole("button", { name: "Sprawdź teraz" }));
    await waitFor(() => expect(checkStatus()).toHaveTextContent("Nie zakolejkowano sprawdzenia"));
    expect(checkStatus()).toHaveTextContent("sprawdzenie już trwa");
    expect(checkStatus()).not.toHaveTextContent("Zakolejkowano sprawdzenie");
  });
});

describe("T21.7 view preference", () => {
  it("opens the stored view when the URL has none", async () => {
    window.localStorage.setItem(CASE_VIEW_STORAGE_KEY, "kanban");
    renderPage("/");
    expect(screen.getByRole("button", { name: "Kanban" })).toHaveAttribute("aria-pressed", "true");
    expect(screen.queryByRole("region", { name: "Lista spraw" })).not.toBeInTheDocument();
  });

  it("lets the explicit URL view win", async () => {
    window.localStorage.setItem(CASE_VIEW_STORAGE_KEY, "kanban");
    renderPage("/?view=list");
    expect(screen.getByRole("button", { name: "Lista" })).toHaveAttribute("aria-pressed", "true");
    await waitForList();
  });

  it("saves only the view, never case data", async () => {
    const user = userEvent.setup();
    const { search } = renderPage("/?q=OPS");
    await waitForList();

    await user.click(screen.getByRole("button", { name: "Kanban" }));
    expect(search().get("view")).toBe("kanban");
    expect(search().get("q")).toBe("OPS");
    expect(Object.keys(window.localStorage)).toEqual([CASE_VIEW_STORAGE_KEY]);
    expect(window.localStorage.getItem(CASE_VIEW_STORAGE_KEY)).toBe("kanban");
    expect(window.sessionStorage.length).toBe(0);

    await user.click(screen.getByRole("button", { name: "Lista" }));
    await waitForList();
    expect(window.localStorage.getItem(CASE_VIEW_STORAGE_KEY)).toBe("list");
  });
});
