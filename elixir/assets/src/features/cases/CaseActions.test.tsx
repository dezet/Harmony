import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { act, render, screen, waitFor, within } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { createMemoryRouter, RouterProvider } from "react-router-dom";
import caseDetailFixture from "@/test/fixtures/case_detail.fixture.json";
import { makeFakeSocket, type FakeSocket } from "@/test/fakeSocket";
import { CaseDetailPage } from "@/features/cases/CaseDetailPage";
import type { CaseDelivery, CaseDetail, Project } from "@/types/contract";

let fakeSocket: FakeSocket;

vi.mock("@/lib/socket", async (importOriginal) => {
  const original = await importOriginal<typeof import("@/lib/socket")>();
  return { ...original, getSocket: () => fakeSocket };
});

const REF = "jira_aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa";
const COMMENT_ID = "aaaaaaaa-bbbb-4aaa-8aaa-aaaaaaaaaaaa";
const SMS_ID = "99999999-9999-4999-8999-999999999999";
const LINEAR_URL = "https://linear.app/acme/issue/LIN-284/eksport-raportu";

const PROJECT: Project = {
  id: "11111111-1111-4111-8111-111111111111",
  slug: "portal-klienta",
  display_name: "Portal klienta",
  ui_color: "purple",
  linear_project_slug: null,
  linear_team_key: null,
  linear_human_review_state: null,
  github_owner: "acme",
  github_repo: "portal",
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

function detailWith(patch: (detail: CaseDetail) => void = () => {}): CaseDetail {
  const detail = structuredClone(caseDetailFixture) as CaseDetail;
  detail.case.linear = { identifier: "LIN-284", url: LINEAR_URL };
  detail.links.linear = { identifier: "LIN-284", url: LINEAR_URL };
  patch(detail);
  return detail;
}

function setDelivery(detail: CaseDetail, id: string, patch: Partial<CaseDelivery>) {
  detail.deliveries = detail.deliveries.map((delivery) => (delivery.id === id ? { ...delivery, ...patch } : delivery));
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
  body: unknown;
}

let detail: CaseDetail;
let calls: Call[];
let onPost: (path: string, body: unknown) => Reply;

const posts = () => calls.filter((call) => call.method === "POST");
const caseReads = () => calls.filter((call) => call.method === "GET" && call.path === `/api/v1/cases/${REF}`);

function actionState(version: number) {
  return {
    ref: REF,
    jira_key: "OPS-142",
    analysis_version: 1,
    analysis_status: "ready",
    acknowledged_at: null,
    repair_approved_at: null,
    repair_approved_version: null,
    version,
  };
}

beforeEach(() => {
  fakeSocket = makeFakeSocket();
  calls = [];
  detail = detailWith();
  onPost = (path) => {
    if (path.endsWith("/approve-repair")) return json({ status: "approved", case: actionState(2), version: 2 });
    if (path.endsWith("/reanalyze")) return json({ analysis_version: 2, case: actionState(2), version: 2 }, 202);
    if (path.startsWith("/api/v1/deliveries/")) return json({ delivery: detail.deliveries[0] }, 202);
    return json({ case: actionState(2), version: 2 });
  };

  vi.stubGlobal(
    "fetch",
    vi.fn(async (input: RequestInfo | URL, init?: RequestInit) => {
      const url = new URL(String(input), "http://localhost");
      const method = init?.method ?? "GET";
      const body = init?.body ? JSON.parse(String(init.body)) : undefined;
      calls.push({ method, path: url.pathname, body });

      if (url.pathname === "/api/v1/csrf") return json({ csrf_token: "csrf-test-token" });
      if (method === "POST") return onPost(url.pathname, body);
      if (url.pathname === `/api/v1/cases/${REF}`) return json(detail);
      if (url.pathname === `/api/v1/cases/${REF}/events`) return json({ items: [], meta: { next_cursor: null, page_size: 50 } });
      if (url.pathname === "/api/v1/cases") {
        return json({
          items: [],
          meta: { next_cursor: null, total: 0, page_size: 25 },
          counts: { all: 0, decision: 0, analysis: 0, done: 0, detected: 0 },
          project_counts: [],
        });
      }
      if (url.pathname === "/api/v1/projects") return json({ projects: [PROJECT] });
      return apiError(404, "not_found");
    }),
  );
});

afterEach(() => {
  vi.unstubAllGlobals();
  vi.restoreAllMocks();
});

function renderCase(url = `/cases/${REF}`) {
  const qc = new QueryClient({ defaultOptions: { queries: { retry: false } } });
  const router = createMemoryRouter([{ path: "/cases/:ref", element: <CaseDetailPage /> }], { initialEntries: [url] });
  render(
    <QueryClientProvider client={qc}>
      <RouterProvider router={router} />
    </QueryClientProvider>,
  );
  return { qc };
}

async function ready() {
  await screen.findByRole("heading", { name: "Eksport raportu kończy się błędem 504" });
}

const actionsRegion = () => screen.getByRole("group", { name: "Akcje sprawy" });
const actionStatus = () => screen.getByRole("status", { name: "Wynik akcji" });

describe("T22.4 acknowledge and approve repair", () => {
  it("acknowledges with the case version only and refreshes the case, history and lists", async () => {
    const user = userEvent.setup();
    const { qc } = renderCase();
    await ready();
    const invalidate = vi.spyOn(qc, "invalidateQueries");

    await user.click(within(actionsRegion()).getByRole("button", { name: "Przyjmij sprawę" }));

    await waitFor(() => expect(actionStatus()).toHaveTextContent("Sprawa przyjęta."));
    expect(posts().map((call) => [call.path, call.body])).toEqual([
      [`/api/v1/cases/${REF}/acknowledge`, { expected_version: 1 }],
    ]);
    const keys = invalidate.mock.calls.map(([filters]) => JSON.stringify(filters?.queryKey));
    expect(keys).toEqual(expect.arrayContaining([JSON.stringify(["case", REF]), JSON.stringify(["case-events", REF]), JSON.stringify(["cases"])]));
    await waitFor(() => expect(caseReads().length).toBeGreaterThan(1));
  });

  it("asks for a described confirmation before approving the repair", async () => {
    const user = userEvent.setup();
    renderCase();
    await ready();

    await user.click(within(actionsRegion()).getByRole("button", { name: "Zatwierdź naprawę" }));
    const dialog = await screen.findByRole("alertdialog", { name: "Zatwierdzić naprawę?" });
    expect(within(dialog).getByText(/może zmienić kod w repozytorium i przygotować pull request/)).toBeInTheDocument();
    expect(within(dialog).getByText("Portal klienta")).toBeInTheDocument();
    expect(await within(dialog).findByText("acme/portal")).toBeInTheDocument();
    expect(within(dialog).getByText("LIN-284")).toBeInTheDocument();
    expect(within(dialog).getByText(/wersji 1/)).toBeInTheDocument();

    await user.click(within(dialog).getByRole("button", { name: "Anuluj" }));
    await waitFor(() => expect(screen.queryByRole("alertdialog")).not.toBeInTheDocument());
    expect(posts()).toEqual([]);

    await user.click(within(actionsRegion()).getByRole("button", { name: "Zatwierdź naprawę" }));
    await user.click(within(await screen.findByRole("alertdialog")).getByRole("button", { name: "Zatwierdź naprawę" }));

    await waitFor(() => expect(actionStatus()).toHaveTextContent("Naprawa zatwierdzona — oczekuje na uruchomienie."));
    expect(posts().map((call) => [call.path, call.body])).toEqual([
      [`/api/v1/cases/${REF}/approve-repair`, { expected_version: 1, analysis_version: 1, confirmed: true }],
    ]);
  });
});

describe("T22.5 errors and backend availability", () => {
  it("shows a stale version next to the action, reloads the case and lets the operator retry", async () => {
    const user = userEvent.setup();
    onPost = () => apiError(409, "stale_version");
    renderCase();
    await ready();

    await user.click(within(actionsRegion()).getByRole("button", { name: "Przyjmij sprawę" }));

    const alert = await within(actionsRegion()).findByRole("alert");
    expect(alert).toHaveTextContent("Sprawa zmieniła się w międzyczasie");
    expect(alert).not.toHaveTextContent("stale_version");
    await waitFor(() => expect(caseReads().length).toBeGreaterThan(1));
    expect(within(actionsRegion()).getByRole("button", { name: "Przyjmij sprawę" })).toBeEnabled();
  });

  it("asks the operator to repeat after a CSRF rejection and never repeats by itself", async () => {
    const user = userEvent.setup();
    onPost = () => apiError(403, "csrf_invalid");
    renderCase();
    await ready();

    await user.click(within(actionsRegion()).getByRole("button", { name: "Przyjmij sprawę" }));

    expect(await within(actionsRegion()).findByRole("alert")).toHaveTextContent("kliknij ponownie");
    expect(posts()).toHaveLength(1);
  });

  it("disables actions from backend reasons, translated into Polish", async () => {
    detail = detailWith((d) => {
      d.actions = {
        acknowledge: { allowed: false, reason: "already_acknowledged" },
        reanalyze: { allowed: false, reason: "effects_disabled" },
        approve_repair: { allowed: false, reason: "analysis_not_published" },
      };
    });
    renderCase();
    await ready();

    const acknowledge = within(actionsRegion()).getByRole("button", { name: "Przyjmij sprawę" });
    const approve = within(actionsRegion()).getByRole("button", { name: "Zatwierdź naprawę" });
    const reanalyze = within(actionsRegion()).getByRole("button", { name: "Przeanalizuj ponownie" });
    expect(acknowledge).toBeDisabled();
    expect(approve).toBeDisabled();
    expect(reanalyze).toBeDisabled();
    expect(acknowledge).toHaveAccessibleDescription("Sprawa została już przyjęta.");
    expect(approve).toHaveAccessibleDescription("Komentarz z analizą nie został jeszcze opublikowany w Jira.");
    expect(reanalyze).toHaveAccessibleDescription(/Efekty zewnętrzne są wyłączone/);
  });

  it("enables an action only when the backend allows it, and hides unknown reason codes", async () => {
    detail = detailWith((d) => {
      d.actions.approve_repair = { allowed: false, reason: "future_rule_code" };
    });
    renderCase();
    await ready();

    const approve = within(actionsRegion()).getByRole("button", { name: "Zatwierdź naprawę" });
    expect(approve).toBeDisabled();
    expect(approve).toHaveAccessibleDescription("Akcja jest teraz niedostępna.");
    expect(screen.queryByText(/future_rule_code/)).not.toBeInTheDocument();
    expect(within(actionsRegion()).getByRole("button", { name: "Przyjmij sprawę" })).toBeEnabled();
  });

  it("shows a publication failure with a retry of the comment only", async () => {
    const user = userEvent.setup();
    detail = detailWith((d) => {
      d.publication = { ...d.publication, status: "failed", comment_id: null, published_at: null, error_code: "jira_comment_permission_denied" };
      setDelivery(d, COMMENT_ID, { status: "failed", last_error_code: "jira_comment_permission_denied", retry_allowed: true });
    });
    renderCase();
    await ready();

    expect(screen.getByText("Analiza gotowa; błąd publikacji")).toBeInTheDocument();
    await user.click(screen.getByRole("button", { name: "Ponów publikację komentarza" }));

    await waitFor(() => expect(posts()).toHaveLength(1));
    expect(posts()[0]).toEqual({
      method: "POST",
      path: `/api/v1/deliveries/${COMMENT_ID}/retry`,
      body: { expected_status: "failed" },
    });
  });

  it("shows a failed publication retry next to that retry", async () => {
    const user = userEvent.setup();
    onPost = () => apiError(409, "reconciliation_required");
    detail = detailWith((d) => {
      d.publication = { ...d.publication, status: "failed", comment_id: null, published_at: null, error_code: "jira_connection_unavailable" };
      setDelivery(d, COMMENT_ID, { status: "failed", last_error_code: "jira_connection_unavailable", retry_allowed: true });
    });
    renderCase();
    await ready();

    await user.click(screen.getByRole("button", { name: "Ponów publikację komentarza" }));
    const publication = screen.getByRole("group", { name: "Publikacja w Jira" });
    expect(await within(publication).findByRole("alert")).toHaveTextContent("ręcznego uzgodnienia");
  });

  it("disables every mutation while the connection is offline", async () => {
    renderCase();
    await ready();

    act(() => fakeSocket.channels[0].reply("error"));

    await waitFor(() => expect(within(actionsRegion()).getByRole("button", { name: "Przyjmij sprawę" })).toBeDisabled());
    expect(within(actionsRegion()).getByRole("button", { name: "Zatwierdź naprawę" })).toBeDisabled();
    expect(screen.getByText(/Brak połączenia z serwerem/)).toBeInTheDocument();
  });
});

describe("T22.6 reanalysis cost and single-delivery retry", () => {
  it("warns about the cost before a reanalysis", async () => {
    const user = userEvent.setup();
    renderCase();
    await ready();

    await user.click(within(actionsRegion()).getByRole("button", { name: "Przeanalizuj ponownie" }));
    const dialog = await screen.findByRole("alertdialog", { name: "Przeanalizować ponownie?" });
    expect(within(dialog).getByText(/płatne/)).toBeInTheDocument();
    expect(within(dialog).getByText(/830 tokenów/)).toBeInTheDocument();
    expect(within(dialog).getByText(/wersja 2/)).toBeInTheDocument();
    expect(posts()).toEqual([]);

    await user.click(within(dialog).getByRole("button", { name: "Przeanalizuj ponownie" }));
    await waitFor(() => expect(actionStatus()).toHaveTextContent("Zlecono analizę w wersji 2."));
    expect(posts().map((call) => [call.path, call.body])).toEqual([
      [`/api/v1/cases/${REF}/reanalyze`, { expected_version: 1, confirmed: true }],
    ]);
  });

  it("retries one delivery with a duplicate-risk confirmation", async () => {
    const user = userEvent.setup();
    detail = detailWith((d) => {
      setDelivery(d, SMS_ID, { status: "unknown", last_error_code: "lease_expired", retry_allowed: true, duplicate_risk: true });
    });
    renderCase(`/cases/${REF}?tab=issue`);
    await ready();

    const effects = screen.getByRole("list", { name: "Efekty integracji" });
    const smsRow = within(effects).getByText("SMS").closest("li")!;
    expect(within(effects).getAllByRole("button", { name: /^Ponów/ })).toHaveLength(1);

    await user.click(within(smsRow).getByRole("button", { name: "Ponów SMS" }));
    const dialog = await screen.findByRole("alertdialog", { name: "Ponowić SMS?" });
    expect(within(dialog).getByText(/duplikat/)).toBeInTheDocument();
    expect(posts()).toEqual([]);

    await user.click(within(dialog).getByRole("button", { name: "Ponów mimo ryzyka" }));
    await waitFor(() => expect(posts()).toHaveLength(1));
    expect(posts()[0]).toEqual({
      method: "POST",
      path: `/api/v1/deliveries/${SMS_ID}/retry`,
      body: { expected_status: "unknown", confirm_duplicate_risk: true },
    });
    expect(calls.some((call) => call.method === "POST" && call.path.startsWith("/api/v1/cases/"))).toBe(false);
  });

  it("offers no retry for a delivery the backend does not allow", async () => {
    detail = detailWith((d) => {
      setDelivery(d, SMS_ID, { status: "unknown", retry_allowed: false, duplicate_risk: true });
    });
    renderCase(`/cases/${REF}?tab=issue`);
    await ready();

    const effects = screen.getByRole("list", { name: "Efekty integracji" });
    expect(within(effects).queryAllByRole("button", { name: /^Ponów/ })).toHaveLength(0);
    expect(within(effects).getByText("Wynik nieznany")).toBeInTheDocument();
  });
});
