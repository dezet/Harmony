import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { act, render, screen, waitFor, within } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { createMemoryRouter, RouterProvider } from "react-router-dom";
import caseDetailFixture from "@/test/fixtures/case_detail.fixture.json";
import casesPageFixture from "@/test/fixtures/cases_page.fixture.json";
import { makeFakeSocket, type FakeSocket } from "@/test/fakeSocket";
import { CasesPage } from "@/features/cases/CasesPage";
import packageJson from "../../../package.json";
import type { CaseColumn, CaseDetail, CaseSummary, CasesPage as CasesPageBody } from "@/types/contract";

// T23: Kanban over the same `GET /cases` data. Each column is its own
// paginated query (`column=`), with the list's filters and order, its own
// cursor and its own total (spec §4.5, §11.2–11.3).

let fakeSocket: FakeSocket;

vi.mock("@/lib/socket", async (importOriginal) => {
  const original = await importOriginal<typeof import("@/lib/socket")>();
  return { ...original, getSocket: () => fakeSocket };
});

const fixture = casesPageFixture as CasesPageBody;
const JIRA_REF = "jira_aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa";
const COLUMN_NAMES = ["Wykryte", "W analizie", "Do decyzji", "Przekazane"];
const PAGE_SIZE = 25;

const FILTER_COLUMNS: Record<string, CaseColumn> = {
  decision: "decision",
  analysis: "analyzing",
  done: "handed_off",
};

function sixtyDetected(): CaseSummary[] {
  const template = fixture.items.find((item) => item.column === "detected")!;
  return Array.from({ length: 60 }, (_, i) => ({
    ...template,
    ref: `jira_detected_${i + 1}`,
    title: `Wykryta sprawa ${i + 1}`,
    jira: { key: `OPS-${1000 + i}`, url: `https://example.atlassian.net/browse/OPS-${1000 + i}` },
  }));
}

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json" } });
}

function apiError(status: number, code: string): Response {
  return json({ error: { code, message: code, fields: {} } }, status);
}

type Reply = Response | Promise<Response>;

interface CasesCall {
  column: string | null;
  cursor: string | null;
  params: URLSearchParams;
}

let dataset: CaseSummary[];
let columnReply: Partial<Record<CaseColumn, (params: URLSearchParams) => Reply>>;
let casesCalls: CasesCall[];
let methods: string[];
let cursorMismatches: string[];

// The cursor is bound to the whole filter set including `column`, like the
// backend's filter hash: a cursor from another scope is a 400.
function scopeOf(params: URLSearchParams): string {
  return ["column", "project", "filter", "q"].map((key) => params.get(key) ?? "").join("|");
}

function matches(item: CaseSummary, params: URLSearchParams, withColumn: boolean): boolean {
  const filterColumn = FILTER_COLUMNS[params.get("filter") ?? ""];
  const column = withColumn ? params.get("column") : null;
  const slug = params.get("project");
  const q = (params.get("q") ?? "").toLowerCase();
  const haystack = `${item.title} ${item.jira?.key ?? ""} ${item.linear?.identifier ?? ""}`.toLowerCase();
  return (
    (!filterColumn || item.column === filterColumn) &&
    (!column || item.column === column) &&
    (!slug || item.project.slug === slug) &&
    (!q || haystack.includes(q))
  );
}

function serveCases(params: URLSearchParams): Response {
  const scope = scopeOf(params);
  const cursor = params.get("cursor");
  let offset = 0;
  if (cursor) {
    const [cursorScope, cursorOffset] = cursor.split("@");
    if (cursorScope !== scope) {
      cursorMismatches.push(`${cursor} → ${scope}`);
      return apiError(400, "invalid_cursor");
    }
    offset = Number(cursorOffset);
  }

  const all = dataset.filter((item) => matches(item, params, true));
  const inScope = dataset.filter((item) => matches(item, new URLSearchParams({ project: params.get("project") ?? "", q: params.get("q") ?? "" }), false));
  const count = (column: CaseColumn) => inScope.filter((item) => item.column === column).length;
  const next = offset + PAGE_SIZE < all.length ? `${scope}@${offset + PAGE_SIZE}` : null;

  return json({
    items: all.slice(offset, offset + PAGE_SIZE),
    meta: { next_cursor: next, total: all.length, page_size: PAGE_SIZE },
    counts: {
      all: inScope.length,
      decision: count("decision"),
      analysis: count("analyzing"),
      done: count("handed_off"),
      detected: count("detected"),
    },
    project_counts: [],
  } satisfies CasesPageBody);
}

function detailFor(ref: string): CaseDetail | null {
  const item = dataset.find((entry) => entry.ref === ref);
  if (!item) return null;
  const detail = structuredClone(caseDetailFixture) as CaseDetail;
  detail.case.ref = item.ref;
  detail.case.title = item.title;
  return detail;
}

const originalMatchMedia = window.matchMedia;

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

beforeEach(() => {
  fakeSocket = makeFakeSocket();
  window.localStorage.clear();
  dataset = fixture.items;
  columnReply = {};
  casesCalls = [];
  methods = [];
  cursorMismatches = [];
  setViewport(true);

  vi.stubGlobal(
    "fetch",
    vi.fn(async (input: RequestInfo | URL, init?: RequestInit) => {
      const url = new URL(String(input), "http://localhost");
      methods.push(init?.method ?? "GET");

      if (/^\/api\/v1\/cases\/[^/]+\/events$/.test(url.pathname)) {
        return json({ items: [], meta: { next_cursor: null, page_size: 50 } });
      }
      const caseMatch = url.pathname.match(/^\/api\/v1\/cases\/([^/]+)$/);
      if (caseMatch) {
        const detail = detailFor(decodeURIComponent(caseMatch[1]));
        return detail ? json(detail) : apiError(404, "not_found");
      }

      switch (url.pathname) {
        case "/api/v1/cases": {
          const column = url.searchParams.get("column") as CaseColumn | null;
          casesCalls.push({ column, cursor: url.searchParams.get("cursor"), params: url.searchParams });
          const override = column ? columnReply[column] : undefined;
          return override ? override(url.searchParams) : serveCases(url.searchParams);
        }
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

function renderPage(url: string) {
  const qc = new QueryClient({ defaultOptions: { queries: { retry: false } } });
  const router = createMemoryRouter([{ path: "/", element: <CasesPage /> }], { initialEntries: [url] });
  render(
    <QueryClientProvider client={qc}>
      <RouterProvider router={router} />
    </QueryClientProvider>,
  );
  return { router, search: () => new URLSearchParams(router.state.location.search) };
}

const board = () => screen.getByRole("region", { name: "Kanban spraw" });
const column = (name: string) => within(board()).getByRole("region", { name });
const cardTitles = (region: HTMLElement) =>
  within(region)
    .queryAllByRole("listitem")
    .map((item) => item.querySelector("[data-slot=case-title]")?.textContent);
const columnCalls = (name: CaseColumn) => casesCalls.filter((call) => call.column === name);
const listCalls = () => casesCalls.filter((call) => call.column === null);

async function waitForCards(name: string, count: number) {
  await waitFor(() => expect(cardTitles(column(name))).toHaveLength(count));
}

describe("T23.1 per-column pagination", () => {
  it("shows 60 detected cards over three pages exactly once and keeps the other columns empty", async () => {
    dataset = sixtyDetected();
    const user = userEvent.setup();
    renderPage("/?view=kanban");

    await screen.findByRole("region", { name: "Kanban spraw" });
    await waitForCards("Wykryte", 25);
    const detected = column("Wykryte");
    expect(within(detected).getByText("60 spraw")).toBeInTheDocument();

    await user.click(within(detected).getByRole("button", { name: "Pokaż więcej" }));
    await waitForCards("Wykryte", 50);
    await user.click(within(detected).getByRole("button", { name: "Pokaż więcej" }));
    await waitForCards("Wykryte", 60);
    expect(within(detected).queryByRole("button", { name: "Pokaż więcej" })).not.toBeInTheDocument();

    const titles = cardTitles(detected);
    expect(new Set(titles).size).toBe(60);
    expect(titles).toEqual(Array.from({ length: 60 }, (_, i) => `Wykryta sprawa ${i + 1}`));
    expect(columnCalls("detected").map((call) => call.cursor)).toEqual([null, "detected|||@25", "detected|||@50"]);

    for (const name of ["W analizie", "Do decyzji", "Przekazane"]) {
      const region = column(name);
      expect(cardTitles(region)).toHaveLength(0);
      expect(within(region).getByText("Brak spraw na tym etapie.")).toBeInTheDocument();
      expect(within(region).getByText("0 spraw")).toBeInTheDocument();
    }
    expect(cursorMismatches).toEqual([]);
  });
});

describe("T23.2 columns and layout", () => {
  it("renders the four columns in the fixed order with their cases", async () => {
    renderPage("/?view=kanban");
    await screen.findByRole("region", { name: "Kanban spraw" });

    const names = within(board())
      .getAllByRole("region")
      .map((region) => region.getAttribute("aria-labelledby"))
      .map((id) => document.getElementById(id ?? "")?.textContent);
    expect(names).toEqual(COLUMN_NAMES);
    for (const name of COLUMN_NAMES) {
      expect(within(column(name)).getByRole("heading", { name })).toBeInTheDocument();
    }

    await waitForCards("W analizie", 2);
    expect(cardTitles(column("W analizie"))).toEqual(["Brak wiadomości po zresetowaniu hasła", "Wdrożenie limitu czasu raportu"]);
    expect(within(column("W analizie")).getByText("Naprawa w toku")).toBeInTheDocument();
    await waitForCards("Do decyzji", 4);
    await waitForCards("Przekazane", 2);
    await waitForCards("Wykryte", 1);
  });

  it("uses four columns above 1150 px, two up to 1150 px and one up to 600 px", async () => {
    renderPage("/?view=kanban");
    const grid = (await screen.findByRole("region", { name: "Kanban spraw" })).querySelector("[data-slot=board-columns]");
    expect(grid).not.toBeNull();
    expect(grid!.className).toContain("grid-cols-4");
    expect(grid!.className).toContain("max-[1150px]:grid-cols-2");
    expect(grid!.className).toContain("max-[600px]:grid-cols-1");
  });
});

describe("T23.3 switching views", () => {
  it("never sends a list cursor to a column or a column cursor to the list", async () => {
    dataset = sixtyDetected();
    const user = userEvent.setup();
    const { search } = renderPage("/?view=list&q=Wykryta");

    const list = await screen.findByRole("region", { name: "Lista spraw" });
    await waitFor(() => expect(within(list).getAllByRole("listitem")).toHaveLength(25));
    await user.click(within(list).getByRole("button", { name: "Pokaż więcej" }));
    await waitFor(() => expect(within(list).getAllByRole("listitem")).toHaveLength(50));

    await user.click(screen.getByRole("button", { name: "Kanban" }));
    expect(search().get("q")).toBe("Wykryta");
    await waitForCards("Wykryte", 25);
    await user.click(within(column("Wykryte")).getByRole("button", { name: "Pokaż więcej" }));
    await waitForCards("Wykryte", 50);

    const firstColumnPages = casesCalls.filter((call) => call.column !== null && call.cursor === null);
    expect(firstColumnPages.map((call) => call.column).sort()).toEqual(["analyzing", "decision", "detected", "handed_off"]);
    for (const call of casesCalls.filter((entry) => entry.column !== null)) {
      expect(call.params.get("q")).toBe("Wykryta");
    }

    await user.click(screen.getByRole("button", { name: "Lista" }));
    const listAgain = await screen.findByRole("region", { name: "Lista spraw" });
    expect(search().get("q")).toBe("Wykryta");
    await waitFor(() => expect(within(listAgain).getAllByRole("listitem")).toHaveLength(50));
    await user.click(within(listAgain).getByRole("button", { name: "Pokaż więcej" }));
    await waitFor(() => expect(within(listAgain).getAllByRole("listitem")).toHaveLength(60));

    expect(cursorMismatches).toEqual([]);
    for (const call of listCalls()) {
      expect(call.cursor === null || call.cursor.startsWith("|")).toBe(true);
    }
    for (const call of casesCalls.filter((entry) => entry.column !== null && entry.cursor !== null)) {
      expect(call.cursor!.startsWith(`${call.column}|`)).toBe(true);
    }
  });

  it("keeps filter, search and the selected case across List→Kanban and Back/Forward", async () => {
    const user = userEvent.setup();
    const { router, search } = renderPage(`/?view=list&filter=decision&q=Eksport&case=${JIRA_REF}`);

    const panel = await screen.findByRole("region", { name: "Szczegóły sprawy" });
    expect(await within(panel).findByRole("heading", { name: "Eksport raportu kończy się błędem 504" })).toBeInTheDocument();

    await user.click(screen.getByRole("button", { name: "Kanban" }));
    expect(search().get("view")).toBe("kanban");
    expect(search().get("filter")).toBe("decision");
    expect(search().get("q")).toBe("Eksport");
    expect(search().get("case")).toBe(JIRA_REF);

    const dialog = await screen.findByRole("dialog", { name: "Szczegóły sprawy" });
    expect(await within(dialog).findByRole("heading", { name: "Eksport raportu kończy się błędem 504" })).toBeInTheDocument();
    await waitFor(() => expect(columnCalls("decision").length).toBeGreaterThan(0));
    for (const call of casesCalls.filter((entry) => entry.column !== null)) {
      expect(call.params.get("filter")).toBe("decision");
      expect(call.params.get("q")).toBe("Eksport");
    }

    await act(() => router.navigate(-1));
    await waitFor(() => expect(screen.queryByRole("dialog")).not.toBeInTheDocument());
    expect(search().get("view")).toBe("list");
    expect(search().get("case")).toBe(JIRA_REF);
    const panelAgain = await screen.findByRole("region", { name: "Szczegóły sprawy" });
    expect(await within(panelAgain).findByRole("heading", { name: "Eksport raportu kończy się błędem 504" })).toBeInTheDocument();

    await act(() => router.navigate(1));
    expect(await screen.findByRole("dialog", { name: "Szczegóły sprawy" })).toBeInTheDocument();
    expect(search().get("view")).toBe("kanban");
    expect(search().get("q")).toBe("Eksport");
  });
});

describe("T23.4 shared detail", () => {
  it("opens the shared detail in a dialog on click, also on desktop, and Escape returns focus to the card", async () => {
    const user = userEvent.setup();
    const { search } = renderPage("/?view=kanban");

    const card = await within(await waitFor(() => column("Do decyzji"))).findByRole("button", {
      name: /Eksport raportu kończy się błędem 504/,
    });
    expect(screen.queryByRole("dialog")).not.toBeInTheDocument();

    await user.click(card);
    const dialog = await screen.findByRole("dialog", { name: "Szczegóły sprawy" });
    expect(await within(dialog).findByRole("heading", { name: "Eksport raportu kończy się błędem 504" })).toBeInTheDocument();
    expect(within(dialog).getByRole("tab", { name: "Analiza" })).toBeInTheDocument();
    expect(search().get("case")).toBe(JIRA_REF);
    expect(screen.queryByRole("region", { name: "Szczegóły sprawy" })).not.toBeInTheDocument();

    await user.keyboard("{Escape}");
    await waitFor(() => expect(screen.queryByRole("dialog")).not.toBeInTheDocument());
    expect(search().has("case")).toBe(false);
    await waitFor(() => expect(within(column("Do decyzji")).getByRole("button", { name: /Eksport raportu/ })).toHaveFocus());
  });

  it("opens the detail with Enter and with Space from the keyboard", async () => {
    const user = userEvent.setup();
    renderPage("/?view=kanban");

    const card = await within(await waitFor(() => column("Przekazane"))).findByRole("button", {
      name: /Nieaktualny zespół w profilu pracownika/,
    });
    act(() => card.focus());

    await user.keyboard("{Enter}");
    const dialog = await screen.findByRole("dialog", { name: "Szczegóły sprawy" });
    expect(await within(dialog).findByRole("heading", { name: "Nieaktualny zespół w profilu pracownika" })).toBeInTheDocument();
    await user.keyboard("{Escape}");
    await waitFor(() => expect(screen.queryByRole("dialog")).not.toBeInTheDocument());
    await waitFor(() => expect(card).toHaveFocus());

    await user.keyboard(" ");
    expect(await screen.findByRole("dialog", { name: "Szczegóły sprawy" })).toBeInTheDocument();
  });
});

describe("T23.5 column states", () => {
  it("keeps the other columns working when one fails or is empty and retries only the failed column", async () => {
    dataset = fixture.items.filter((item) => item.column !== "handed_off");
    columnReply.decision = () => apiError(500, "internal_error");
    const user = userEvent.setup();
    renderPage("/?view=kanban");

    await screen.findByRole("region", { name: "Kanban spraw" });
    const decision = column("Do decyzji");
    expect(await within(decision).findByRole("alert")).toHaveTextContent("Nie udało się wczytać kolumny.");
    await waitForCards("W analizie", 2);
    await waitForCards("Wykryte", 1);
    expect(within(column("Przekazane")).getByText("Brak spraw na tym etapie.")).toBeInTheDocument();

    const before = { detected: columnCalls("detected").length, analyzing: columnCalls("analyzing").length };
    delete columnReply.decision;
    await user.click(within(decision).getByRole("button", { name: "Spróbuj ponownie" }));
    await waitForCards("Do decyzji", 4);
    expect(within(column("Do decyzji")).getByText("4 sprawy")).toBeInTheDocument();
    expect(columnCalls("detected")).toHaveLength(before.detected);
    expect(columnCalls("analyzing")).toHaveLength(before.analyzing);
  });

  it("counts a column from meta.total, not from the loaded cards", async () => {
    columnReply.analyzing = (params) => {
      const page = JSON.parse(JSON.stringify(fixture)) as CasesPageBody;
      page.items = fixture.items.filter((item) => item.column === "analyzing");
      page.meta = { next_cursor: `${scopeOf(params)}@2`, total: 37, page_size: PAGE_SIZE };
      return json(page);
    };
    renderPage("/?view=kanban");

    await screen.findByRole("region", { name: "Kanban spraw" });
    await waitForCards("W analizie", 2);
    const analyzing = column("W analizie");
    expect(within(analyzing).getByText("37 spraw")).toBeInTheDocument();
    expect(within(analyzing).getByRole("button", { name: "Pokaż więcej" })).toBeInTheDocument();
  });
});

describe("T23.6 no drag and drop, no mutations", () => {
  it("renders plain cards without drag handles and only reads data", async () => {
    const user = userEvent.setup();
    renderPage("/?view=kanban");

    const card = await within(await waitFor(() => column("Wykryte"))).findByRole("button", {
      name: /Załącznik nie otwiera się w przeglądarce/,
    });
    await user.click(card);
    await screen.findByRole("dialog", { name: "Szczegóły sprawy" });
    await user.keyboard("{Escape}");
    await waitFor(() => expect(screen.queryByRole("dialog")).not.toBeInTheDocument());

    expect(document.querySelectorAll("[draggable=true]")).toHaveLength(0);
    expect(document.querySelectorAll("[aria-roledescription]")).toHaveLength(0);
    expect(new Set(methods)).toEqual(new Set(["GET"]));

    const dependencies = Object.keys({ ...packageJson.dependencies, ...packageJson.devDependencies });
    expect(dependencies.filter((name) => /dnd|drag|sortable/i.test(name))).toEqual([]);
  });
});
