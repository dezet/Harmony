import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { act, render, screen, waitFor, within } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { createMemoryRouter, RouterProvider } from "react-router-dom";
import caseDetailFixture from "@/test/fixtures/case_detail.fixture.json";
import casesPageFixture from "@/test/fixtures/cases_page.fixture.json";
import { makeFakeSocket, type FakeSocket } from "@/test/fakeSocket";
import { CaseDetailPage } from "@/features/cases/CaseDetailPage";
import { CasesPage } from "@/features/cases/CasesPage";
import type { AgentWorkDetail, CaseDetail, CaseEvent, CaseEventsPage, CasesPage as CasesPageBody } from "@/types/contract";

let fakeSocket: FakeSocket;

vi.mock("@/lib/socket", async (importOriginal) => {
  const original = await importOriginal<typeof import("@/lib/socket")>();
  return { ...original, getSocket: () => fakeSocket };
});

const JIRA_REF = "jira_aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa";
const OTHER_REF = "jira_cccccccc-cccc-4ccc-8ccc-cccccccccccc";
const RUN_REF = "run_ffffffff-2222-4222-8222-222222222222";
const LINEAR_URL = "https://linear.app/acme/issue/LIN-284/eksport-raportu";

function jiraDetail(patch: (detail: CaseDetail) => void = () => {}): CaseDetail {
  const detail = structuredClone(caseDetailFixture) as CaseDetail;
  detail.case.linear = { identifier: "LIN-284", url: LINEAR_URL };
  detail.links.linear = { identifier: "LIN-284", url: LINEAR_URL };
  patch(detail);
  return detail;
}

function otherDetail(): CaseDetail {
  return jiraDetail((detail) => {
    detail.case.ref = OTHER_REF;
    detail.case.title = "Różnica w sumie faktur po imporcie";
    detail.case.jira = { key: "FIN-87", url: "https://example.atlassian.net/browse/FIN-87" };
    detail.links.jira = detail.case.jira;
  });
}

function agentDetail(): AgentWorkDetail {
  const summary = (casesPageFixture as CasesPageBody).items.find((item) => item.ref === RUN_REF)!;
  const linear = { identifier: "LIN-302", url: "https://linear.app/acme/issue/LIN-302/ci-portal" };
  const unsupported = { allowed: false, reason: "unsupported_case_kind" };
  return {
    case: {
      ...summary,
      linear,
      project_id: summary.project.id,
      work_run: { id: "ffffffff-2222-4222-8222-222222222222", type: "implementation", status: "failed", agent_backend: "codex", forge: null },
    },
    analysis: null,
    links: { jira: null, linear },
    deliveries: [],
    actions: { acknowledge: unsupported, reanalyze: unsupported, approve_repair: unsupported },
    publication: null,
    version: null,
  };
}

function event(id: string, type: string, patch: Partial<CaseEvent> = {}): CaseEvent {
  return {
    id,
    type,
    actor: "system",
    occurred_at: "2026-09-22T10:12:00Z",
    operation: null,
    recipient: null,
    payload: {},
    ...patch,
  };
}

function eventsPage(items: CaseEvent[]): CaseEventsPage {
  return { items, meta: { next_cursor: null, page_size: 50 } };
}

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json" } });
}

function apiError(status: number, code: string): Response {
  return json({ error: { code, message: code, fields: {} } }, status);
}

function deferred() {
  let resolve!: (response: Response) => void;
  const promise = new Promise<Response>((r) => {
    resolve = r;
  });
  return { promise, resolve };
}

type Reply = Response | Promise<Response>;

let details: Record<string, CaseDetail | AgentWorkDetail>;
let onEvents: (ref: string) => Reply;
let calls: { method: string; path: string }[];

function setViewport(desktop: boolean) {
  Object.defineProperty(window, "matchMedia", {
    writable: true,
    configurable: true,
    value: (query: string): MediaQueryList =>
      ({
        matches: desktop && query === "(min-width: 601px)",
        media: query,
        onchange: null,
        addListener: () => {},
        removeListener: () => {},
        addEventListener: () => {},
        removeEventListener: () => {},
        dispatchEvent: () => false,
      }) as unknown as MediaQueryList,
  });
}

const originalMatchMedia = window.matchMedia;

beforeEach(() => {
  fakeSocket = makeFakeSocket();
  window.localStorage.clear();
  calls = [];
  details = { [JIRA_REF]: jiraDetail(), [OTHER_REF]: otherDetail(), [RUN_REF]: agentDetail() };
  onEvents = () => json(eventsPage([]));

  vi.stubGlobal(
    "fetch",
    vi.fn(async (input: RequestInfo | URL, init?: RequestInit) => {
      const url = new URL(String(input), "http://localhost");
      calls.push({ method: init?.method ?? "GET", path: url.pathname });
      const eventsMatch = url.pathname.match(/^\/api\/v1\/cases\/([^/]+)\/events$/);
      if (eventsMatch) return onEvents(decodeURIComponent(eventsMatch[1]));
      const caseMatch = url.pathname.match(/^\/api\/v1\/cases\/([^/]+)$/);
      if (caseMatch) {
        const detail = details[decodeURIComponent(caseMatch[1])];
        return detail ? json(detail) : apiError(404, "not_found");
      }
      switch (url.pathname) {
        case "/api/v1/cases":
          return json(casesPageFixture);
        case "/api/v1/projects":
          return json({ projects: [] });
        case "/api/v1/automations":
          return json({ items: [], meta: { next_cursor: null, page_size: 100 } });
        default:
          return apiError(404, "not_found");
      }
    }),
  );
});

afterEach(() => {
  Object.defineProperty(window, "matchMedia", { writable: true, configurable: true, value: originalMatchMedia });
  vi.unstubAllGlobals();
  vi.restoreAllMocks();
});

function renderAt(url: string) {
  const qc = new QueryClient({ defaultOptions: { queries: { retry: false } } });
  const router = createMemoryRouter(
    [
      { path: "/", element: <CasesPage /> },
      { path: "/cases/:ref", element: <CaseDetailPage /> },
      { path: "/projects/:slug/runs/:identifier", element: <p>Szczegół przebiegu</p> },
    ],
    { initialEntries: [url] },
  );
  render(
    <QueryClientProvider client={qc}>
      <RouterProvider router={router} />
    </QueryClientProvider>,
  );
  return { router, qc, search: () => new URLSearchParams(router.state.location.search) };
}

async function waitForTitle(title = "Eksport raportu kończy się błędem 504") {
  return screen.findByRole("heading", { name: title });
}

describe("T22.1 Jira and Linear links", () => {
  it("renders both links with the same variant and size, opening a new tab safely", async () => {
    renderAt(`/cases/${JIRA_REF}`);
    await waitForTitle();

    const jira = screen.getByRole("link", { name: /Zobacz w Jira/ });
    const linear = screen.getByRole("link", { name: /Zobacz w Linear/ });
    expect(jira).toHaveAttribute("href", "https://example.atlassian.net/browse/OPS-142");
    expect(linear).toHaveAttribute("href", LINEAR_URL);
    for (const link of [jira, linear]) {
      expect(link).toHaveAttribute("target", "_blank");
      expect(link).toHaveAttribute("rel", "noopener noreferrer");
    }
    expect(jira.className).toBe(linear.className);
  });

  it("disables a link without URL, explains why and never renders href=#", async () => {
    details[JIRA_REF] = jiraDetail((detail) => {
      detail.case.linear = null;
      detail.links.linear = null;
    });
    renderAt(`/cases/${JIRA_REF}`);
    await waitForTitle();

    expect(screen.queryByRole("link", { name: /Zobacz w Linear/ })).not.toBeInTheDocument();
    const linear = screen.getByRole("button", { name: /Zobacz w Linear/ });
    expect(linear).toBeDisabled();
    expect(linear).toHaveAccessibleDescription("Zadanie Linear nie zostało jeszcze potwierdzone.");
    expect(document.querySelector('a[href="#"]')).toBeNull();
    expect(linear.className).toBe(screen.getByRole("link", { name: /Zobacz w Jira/ }).className);
  });

  it("refuses javascript:, data: and untrusted hosts", async () => {
    details[JIRA_REF] = jiraDetail((detail) => {
      detail.links.jira = { key: "OPS-142", url: "javascript:alert(1)" };
      detail.links.linear = { identifier: "LIN-284", url: "https://linear.evil.example/issue/LIN-284" };
    });
    renderAt(`/cases/${JIRA_REF}`);
    await waitForTitle();

    expect(screen.queryAllByRole("link", { name: /Zobacz w/ })).toHaveLength(0);
    expect(screen.getByRole("button", { name: /Zobacz w Jira/ })).toBeDisabled();
    expect(screen.getByRole("button", { name: /Zobacz w Linear/ })).toBeDisabled();
    expect(document.querySelector('a[href^="javascript:"], a[href^="data:"]')).toBeNull();
  });
});

describe("T22.2 tabs", () => {
  it("exposes ARIA tabs and keeps the active tab in the URL", async () => {
    const user = userEvent.setup();
    const { search } = renderAt(`/cases/${JIRA_REF}`);
    await waitForTitle();

    const tablist = screen.getByRole("tablist", { name: "Sekcje sprawy" });
    const tabs = within(tablist).getAllByRole("tab");
    expect(tabs.map((tab) => tab.textContent)).toEqual(["Analiza", "Zgłoszenie", "Historia"]);
    expect(screen.getByRole("tab", { name: "Analiza" })).toHaveAttribute("aria-selected", "true");

    await user.click(screen.getByRole("tab", { name: "Historia" }));
    expect(search().get("tab")).toBe("history");
    expect(screen.getByRole("tabpanel", { name: "Historia" })).toBeInTheDocument();

    await user.click(screen.getByRole("tab", { name: "Analiza" }));
    expect(search().has("tab")).toBe(false);
  });

  it("opens the tab named by the URL and normalizes an invalid one", async () => {
    renderAt(`/cases/${JIRA_REF}?tab=issue`);
    await waitForTitle();
    expect(screen.getByRole("tab", { name: "Zgłoszenie" })).toHaveAttribute("aria-selected", "true");
  });

  it("replaces an invalid tab with the default", async () => {
    const { search } = renderAt(`/cases/${JIRA_REF}?tab=bogus`);
    await waitForTitle();
    await waitFor(() => expect(search().has("tab")).toBe(false));
    expect(screen.getByRole("tab", { name: "Analiza" })).toHaveAttribute("aria-selected", "true");
  });

  it("gives the history tab its own loading and empty states", async () => {
    const pending = deferred();
    onEvents = () => pending.promise;
    renderAt(`/cases/${JIRA_REF}?tab=history`);
    await waitForTitle();

    const panel = screen.getByRole("tabpanel", { name: "Historia" });
    expect(within(panel).getByRole("status")).toHaveTextContent("Wczytywanie historii…");
    await act(async () => pending.resolve(json(eventsPage([]))));
    expect(await within(panel).findByText("Brak zdarzeń w historii tej sprawy.")).toBeInTheDocument();
  });

  it("gives the issue tab its own empty states", async () => {
    const user = userEvent.setup();
    details[JIRA_REF] = jiraDetail((detail) => {
      detail.case.description_text = "";
      detail.deliveries = [];
    });
    renderAt(`/cases/${JIRA_REF}`);
    await waitForTitle();

    await user.click(screen.getByRole("tab", { name: "Zgłoszenie" }));
    const panel = screen.getByRole("tabpanel", { name: "Zgłoszenie" });
    expect(within(panel).getByText("Zgłoszenie nie ma opisu.")).toBeInTheDocument();
    expect(within(panel).getByText("Brak efektów integracji dla tej sprawy.")).toBeInTheDocument();
  });

  it("shows a history error with a retry, separate from the case detail", async () => {
    const user = userEvent.setup();
    onEvents = () => apiError(503, "action_unavailable");
    renderAt(`/cases/${JIRA_REF}?tab=history`);
    await waitForTitle();

    const panel = screen.getByRole("tabpanel", { name: "Historia" });
    expect(await within(panel).findByRole("alert")).toHaveTextContent("Nie udało się wczytać historii.");
    onEvents = () => json(eventsPage([event("e1", "case_detected")]));
    await user.click(within(panel).getByRole("button", { name: "Spróbuj ponownie" }));
    expect(await within(panel).findByText("Wykryto zgłoszenie spełniające regułę")).toBeInTheDocument();
    expect(screen.getByRole("heading", { name: "Eksport raportu kończy się błędem 504" })).toBeInTheDocument();
  });

  it("does not show the history of the previous case after switching cases", async () => {
    const pendingA = deferred();
    const pendingB = deferred();
    onEvents = (ref) => (ref === JIRA_REF ? pendingA.promise : pendingB.promise);
    const { router } = renderAt(`/cases/${JIRA_REF}?tab=history`);
    await waitForTitle();

    await act(() => router.navigate(`/cases/${OTHER_REF}?tab=history`));
    await waitForTitle("Różnica w sumie faktur po imporcie");
    // The late answer for the first case lands in its own cache entry.
    await act(async () => pendingA.resolve(json(eventsPage([event("a1", "case_acknowledged")]))));
    const panel = screen.getByRole("tabpanel", { name: "Historia" });
    expect(within(panel).getByRole("status")).toHaveTextContent("Wczytywanie historii…");
    expect(within(panel).queryByText("Sprawa przyjęta przez operatora")).not.toBeInTheDocument();

    await act(async () => pendingB.resolve(json(eventsPage([event("b1", "repair_approved")]))));
    expect(await within(panel).findByText("Zatwierdzono naprawę")).toBeInTheDocument();
    expect(within(panel).queryByText("Sprawa przyjęta przez operatora")).not.toBeInTheDocument();
  });

  it("shows events in local time with the full date, masked recipients and no raw payload", async () => {
    onEvents = () =>
      json(
        eventsPage([
          event("e1", "delivery_succeeded", {
            operation: "sms",
            recipient: "+48*******89",
            payload: { provider_id: "smsapi-1", secret_note: "<b>nie pokazuj</b>" },
          }),
        ]),
      );
    renderAt(`/cases/${JIRA_REF}?tab=history`);
    await waitForTitle();

    const panel = screen.getByRole("tabpanel", { name: "Historia" });
    expect(await within(panel).findByText("Wysyłka zakończona powodzeniem")).toBeInTheDocument();
    expect(within(panel).getByText(/SMS · \+48\*{7}89/)).toBeInTheDocument();
    expect(within(panel).queryByText(/nie pokazuj/)).not.toBeInTheDocument();
    const time = panel.querySelector("time");
    expect(time).toHaveAttribute("dateTime", "2026-09-22T10:12:00Z");
    expect(time?.getAttribute("title")).toMatch(/2026/);
  });
});

describe("T22.3 analysis result", () => {
  it("shows facts with sources, hypotheses as hypotheses, missing data and the run metadata", async () => {
    details[JIRA_REF] = jiraDetail((detail) => {
      detail.analysis!.input_snapshot = { context_scope: "issue_and_repository", jira_key: "OPS-142", repo_sha: "0123456789abcdef0123" };
      detail.analysis!.result!.context_scope = "issue_and_repository";
    });
    renderAt(`/cases/${JIRA_REF}`);
    await waitForTitle();

    const panel = screen.getByRole("tabpanel", { name: "Analiza" });
    expect(within(panel).getByText("Duży zakres dat może przekraczać limit czasu bramy API.")).toBeInTheDocument();
    const facts = within(panel).getByRole("list", { name: "Fakty" });
    expect(within(facts).getByText("Błąd pojawia się przy dużym zakresie dat.")).toBeInTheDocument();
    expect(within(facts).getByText("Źródło: jira:OPS-142")).toBeInTheDocument();
    const hypotheses = within(panel).getByRole("list", { name: "Hipotezy" });
    expect(within(hypotheses).getByText("Hipoteza")).toBeInTheDocument();
    expect(within(hypotheses).getByText("Pewność: średnia")).toBeInTheDocument();
    expect(within(hypotheses).getByText("Prawdopodobny limit czasu żądania.")).toBeInTheDocument();
    expect(within(panel).getByText(/Hipotezy wymagają potwierdzenia/)).toBeInTheDocument();
    const missing = within(panel).getByRole("list", { name: "Brakujące dane" });
    expect(within(missing).getByText("Log bramy i czas wykonania zapytania.")).toBeInTheDocument();
    expect(within(panel).getByText("Następny krok")).toBeInTheDocument();
    expect(within(panel).getByText(/Zebrać logi dla wskazanego żądania/)).toBeInTheDocument();
    expect(within(panel).getByText("wersja 1")).toBeInTheDocument();
    expect(within(panel).getByText(/gpt-5/)).toBeInTheDocument();
    expect(within(panel).getByText("SHA 0123456789ab")).toBeInTheDocument();
  });

  it("marks an issue-only analysis as not confirmed against the code", async () => {
    renderAt(`/cases/${JIRA_REF}`);
    await waitForTitle();
    expect(screen.getByText(/Analiza objęła tylko treść zgłoszenia/)).toBeInTheDocument();
  });

  it("renders HTML from the analysis and the issue as text, never as markup", async () => {
    const user = userEvent.setup();
    details[JIRA_REF] = jiraDetail((detail) => {
      detail.analysis!.result!.summary = '<img src=x onerror="alert(1)">Podsumowanie';
      detail.case.description_text = "<script>alert(1)</script>Opis zgłoszenia";
    });
    renderAt(`/cases/${JIRA_REF}`);
    await waitForTitle();

    expect(screen.getByText('<img src=x onerror="alert(1)">Podsumowanie')).toBeInTheDocument();
    expect(document.querySelector("img")).toBeNull();
    await user.click(screen.getByRole("tab", { name: "Zgłoszenie" }));
    expect(screen.getByText("<script>alert(1)</script>Opis zgłoszenia")).toBeInTheDocument();
    expect(document.querySelector("script")).toBeNull();
  });

  it("shows a queued analysis without an invented result", async () => {
    details[JIRA_REF] = jiraDetail((detail) => {
      detail.analysis = null;
      detail.case.analysis_status = "queued";
    });
    renderAt(`/cases/${JIRA_REF}`);
    await waitForTitle();

    const panel = screen.getByRole("tabpanel", { name: "Analiza" });
    expect(within(panel).getByText("Analiza oczekuje w kolejce")).toBeInTheDocument();
    expect(within(panel).queryByText("Ustalenia agenta")).not.toBeInTheDocument();
  });

  it("shows a failed analysis as an error, not as findings", async () => {
    details[JIRA_REF] = jiraDetail((detail) => {
      detail.analysis!.status = "failed";
      detail.analysis!.result = null;
      detail.analysis!.error_code = "analysis_timeout";
      detail.case.analysis_status = "failed";
    });
    renderAt(`/cases/${JIRA_REF}`);
    await waitForTitle();

    const panel = screen.getByRole("tabpanel", { name: "Analiza" });
    expect(within(panel).getByRole("alert")).toHaveTextContent("Analiza zakończyła się błędem");
    expect(within(panel).getByText(/przekroczyła limit czasu/)).toBeInTheDocument();
    expect(within(panel).queryByText("Ustalenia agenta")).not.toBeInTheDocument();
  });
});

describe("T22.7 detail placement", () => {
  it("works as a standalone deep link with a way back", async () => {
    renderAt(`/cases/${JIRA_REF}`);

    expect(await screen.findByRole("heading", { level: 1, name: "Eksport raportu kończy się błędem 504" })).toBeInTheDocument();
    expect(screen.getByRole("link", { name: /Centrum spraw/ })).toHaveAttribute("href", "/");
    expect(screen.getByText("Tylko analiza")).toBeInTheDocument();
    expect(screen.getByText("Portal klienta", { selector: "[data-slot=case-project]" })).toBeInTheDocument();
    await waitFor(() => expect(document.title).toBe("OPS-142 — Harmony"));
  });

  it("answers an unknown case with 404 and a way back", async () => {
    renderAt("/cases/jira_00000000-0000-4000-8000-000000000000");

    expect(await screen.findByRole("heading", { name: "Nie znaleziono sprawy" })).toBeInTheDocument();
    expect(screen.getByRole("link", { name: "Wróć do Centrum spraw" })).toHaveAttribute("href", "/");
  });

  it("shows the selected case in a side panel on desktop, without a dialog", async () => {
    setViewport(true);
    renderAt("/");

    const panel = await screen.findByRole("region", { name: "Szczegóły sprawy" });
    expect(await within(panel).findByRole("heading", { name: "Eksport raportu kończy się błędem 504" })).toBeInTheDocument();
    expect(screen.queryByRole("dialog")).not.toBeInTheDocument();
  });

  it("opens the detail as a dialog on a phone and restores focus when it closes", async () => {
    setViewport(false);
    const user = userEvent.setup();
    const { search } = renderAt("/");
    const item = await screen.findByRole("button", { name: /Różnica w sumie faktur po imporcie/ });
    expect(screen.queryByRole("dialog")).not.toBeInTheDocument();
    expect(screen.queryByRole("region", { name: "Szczegóły sprawy" })).not.toBeInTheDocument();

    await user.click(item);
    const dialog = await screen.findByRole("dialog", { name: "Szczegóły sprawy" });
    expect(await within(dialog).findByRole("heading", { name: "Różnica w sumie faktur po imporcie" })).toBeInTheDocument();
    expect(search().get("case")).toBe(OTHER_REF);

    await user.keyboard("{Escape}");
    await waitFor(() => expect(screen.queryByRole("dialog")).not.toBeInTheDocument());
    expect(search().has("case")).toBe(false);
    await waitFor(() => expect(screen.getByRole("button", { name: /Różnica w sumie faktur po imporcie/ })).toHaveFocus());
  });
});

describe("T22.8 legacy agent work", () => {
  it("shows no invented Jira analysis and links to the existing run history", async () => {
    renderAt(`/cases/${RUN_REF}`);
    await waitForTitle("Naprawa nieudanego CI dla portalu");

    const panel = screen.getByRole("tabpanel", { name: "Analiza" });
    expect(within(panel).getByText("Brak analizy Jira")).toBeInTheDocument();
    expect(within(panel).queryByText("Ustalenia agenta")).not.toBeInTheDocument();
    expect(within(panel).getByRole("link", { name: "Historia i dowody przebiegu" })).toHaveAttribute(
      "href",
      "/projects/portal-klienta/runs/LIN-302",
    );
    const jira = screen.getByRole("button", { name: /Zobacz w Jira/ });
    expect(jira).toBeDisabled();
    expect(jira).toHaveAccessibleDescription("Brak powiązania Jira.");
    expect(screen.getByRole("link", { name: /Zobacz w Linear/ })).toHaveAttribute(
      "href",
      "https://linear.app/acme/issue/LIN-302/ci-portal",
    );
    expect(screen.queryByRole("button", { name: "Przyjmij sprawę" })).not.toBeInTheDocument();
    expect(screen.getByText(/Decyzje dotyczą tylko spraw z Jira/)).toBeInTheDocument();
  });
});
