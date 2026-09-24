import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { render, screen, waitFor, within } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { createMemoryRouter, RouterProvider } from "react-router-dom";
import { AutomationsPage } from "@/features/automations/AutomationsPage";
import {
  apiError,
  installAutomationServer,
  json,
  makeRule,
  RULE_ID,
  type AutomationServer,
} from "@/test/automationServer";
import type { AutomationRule } from "@/types/contract";

const PAUSED_ID = "55555555-1111-4555-8555-555555555555";
const DRAFT_ID = "55555555-2222-4555-8555-555555555555";
const FAILING_ID = "55555555-3333-4555-8555-555555555555";

const timeFormat = new Intl.DateTimeFormat("pl-PL", { dateStyle: "short", timeStyle: "short" });
const at = (iso: string) => timeFormat.format(new Date(iso));

let server: AutomationServer;

function renderPage() {
  const queryClient = new QueryClient({
    defaultOptions: { queries: { retry: false }, mutations: { retry: false } },
  });
  const router = createMemoryRouter(
    [
      { path: "/automations", element: <AutomationsPage /> },
      { path: "/automations/:id", element: <p>Edytor</p> },
    ],
    { initialEntries: ["/automations"] },
  );
  render(
    <QueryClientProvider client={queryClient}>
      <RouterProvider router={router} />
    </QueryClientProvider>,
  );
  return { router };
}

const activeRule = () =>
  makeRule({
    enabled: true,
    activated_at: "2026-09-20T10:00:00Z",
    baseline_complete_at: "2026-09-20T10:01:00Z",
    last_success_at: "2026-09-24T12:00:00Z",
    next_poll_at: "2026-09-24T12:05:00Z",
  });

const row = (name: string) => screen.getByRole("listitem", { name });

beforeEach(() => {
  server = installAutomationServer([
    activeRule(),
    makeRule({
      id: PAUSED_ID,
      name: "Wstrzymana reguła",
      source_type: "filter",
      source_id: "10010",
      interval_seconds: 3600,
      activated_at: "2026-09-10T10:00:00Z",
      baseline_complete_at: "2026-09-10T10:01:00Z",
      last_success_at: "2026-09-23T08:00:00Z",
    }),
    makeRule({ id: DRAFT_ID, name: "Szkic reguły", priority_ids: ["3"] }),
    makeRule({
      id: FAILING_ID,
      name: "Reguła z błędem",
      enabled: true,
      activated_at: "2026-09-10T10:00:00Z",
      last_error_code: "scan_limit_exceeded",
    }),
  ]);
});

afterEach(() => {
  vi.unstubAllGlobals();
});

describe("lista reguł", () => {
  it("pokazuje projekt, źródło, priorytety, częstotliwość, stan, terminy i błąd", async () => {
    renderPage();

    expect(await screen.findByRole("heading", { level: 1, name: "Automatyzacje" })).toBeInTheDocument();
    const active = await screen.findByRole("listitem", { name: "Pilne zgłoszenia" });
    expect(within(active).getByRole("link", { name: "Pilne zgłoszenia" })).toHaveAttribute(
      "href",
      `/automations/${RULE_ID}`,
    );
    expect(active).toHaveTextContent("Portal klienta");
    expect(active).toHaveTextContent("Tablica · ID 42");
    await waitFor(() => expect(active).toHaveTextContent("Krytyczny, Wysoki"));
    expect(active).toHaveTextContent("co 5 min");
    expect(active).toHaveTextContent("Aktywna");
    expect(active).toHaveTextContent(`Ostatni sukces: ${at("2026-09-24T12:00:00Z")}`);
    expect(active).toHaveTextContent(`Następne sprawdzenie: ${at("2026-09-24T12:05:00Z")}`);

    const paused = row("Wstrzymana reguła");
    expect(paused).toHaveTextContent("Zapisany filtr · ID 10010");
    expect(paused).toHaveTextContent("co 1 godz.");
    expect(paused).toHaveTextContent("Wstrzymana");

    const draft = row("Szkic reguły");
    expect(draft).toHaveTextContent("Nieaktywna");
    expect(within(draft).queryByRole("switch")).toBeNull();
    expect(within(draft).getByRole("link", { name: "Aktywuj w edytorze" })).toHaveAttribute(
      "href",
      `/automations/${DRAFT_ID}`,
    );

    expect(row("Reguła z błędem")).toHaveTextContent(/Źródło zwraca zbyt wiele zgłoszeń/);
    expect(screen.getByRole("link", { name: "Nowa reguła" })).toHaveAttribute("href", "/automations/new");
  });

  it("pusta lista zachęca do utworzenia reguły, a błąd ma ponowienie", async () => {
    let failures = 1;
    server.on("GET /api/v1/automations", () =>
      failures-- > 0 ? apiError(503, "action_unavailable") : json({ items: [], meta: { next_cursor: null } }),
    );
    const user = userEvent.setup();
    renderPage();

    expect(await screen.findByText("Nie udało się wczytać reguł.")).toBeInTheDocument();
    await user.click(screen.getByRole("button", { name: "Spróbuj ponownie" }));
    expect(await screen.findByText("Nie masz jeszcze reguł Jira")).toBeInTheDocument();
  });

  it("doczytuje kolejną stronę reguł cursorem", async () => {
    server.on("GET /api/v1/automations", (call) =>
      call.search.get("cursor") === "rules-2"
        ? json({ items: [makeRule({ id: DRAFT_ID, name: "Druga strona" })], meta: { next_cursor: null } })
        : json({ items: [activeRule()], meta: { next_cursor: "rules-2" } }),
    );
    const user = userEvent.setup();
    renderPage();

    await screen.findByRole("listitem", { name: "Pilne zgłoszenia" });
    await user.click(screen.getByRole("button", { name: "Wczytaj więcej reguł" }));
    expect(await screen.findByRole("listitem", { name: "Druga strona" })).toBeInTheDocument();
  });
});

describe("T24.8 pauza, wznowienie i następny termin z odpowiedzi backendu", () => {
  it("pauza czeka na backend i pokazuje zwrócony stan", async () => {
    let release: (response: Response) => void = () => {};
    server.on(`POST /api/v1/automations/${RULE_ID}/pause`, (call) => {
      const current = server.rules.get(RULE_ID) as AutomationRule;
      const next = { ...current, enabled: false, next_poll_at: null };
      server.rules.set(RULE_ID, next);
      expect(call.body).toEqual({ version: 1 });
      return new Promise<Response>((resolve) => {
        release = resolve;
      }).then(() => json({ rule: next }));
    });
    const user = userEvent.setup();
    renderPage();
    const active = await screen.findByRole("listitem", { name: "Pilne zgłoszenia" });
    const toggle = within(active).getByRole("switch", { name: "Reguła Pilne zgłoszenia aktywna" });

    expect(toggle).toHaveAttribute("aria-checked", "true");
    await user.click(toggle);
    await waitFor(() => expect(server.requests("POST", `/api/v1/automations/${RULE_ID}/pause`)).toHaveLength(1));
    expect(toggle).toHaveAttribute("aria-checked", "true");
    expect(active).toHaveTextContent("Aktywna");

    release(new Response());
    await waitFor(() => expect(toggle).toHaveAttribute("aria-checked", "false"));
    expect(active).toHaveTextContent("Wstrzymana");
    expect(active).toHaveTextContent("Następne sprawdzenie: —");
    expect(server.requests("POST", `/api/v1/automations/${RULE_ID}/activate`)).toHaveLength(0);
  });

  it("wznowienie wymaga potwierdzenia i pokazuje termin z odpowiedzi", async () => {
    server.on(`POST /api/v1/automations/${PAUSED_ID}/activate`, (call) => {
      expect(call.body).toEqual({ version: 1, confirmed: true });
      const next = { ...(server.rules.get(PAUSED_ID) as AutomationRule), enabled: true, next_poll_at: "2026-09-24T13:00:00Z" };
      server.rules.set(PAUSED_ID, next);
      return json({ status: "enabled", rule: next }, 202);
    });
    const user = userEvent.setup();
    renderPage();
    const paused = await screen.findByRole("listitem", { name: "Wstrzymana reguła" });

    await user.click(within(paused).getByRole("switch", { name: "Reguła Wstrzymana reguła aktywna" }));
    const dialog = await screen.findByRole("alertdialog", { name: "Wznowić regułę?" });
    expect(within(dialog).getByText(/bez nowego skanu bazowego/)).toBeInTheDocument();
    expect(server.requests("POST", `/api/v1/automations/${PAUSED_ID}/activate`)).toHaveLength(0);
    await user.click(within(dialog).getByRole("button", { name: "Wznów regułę" }));

    await waitFor(() => expect(paused).toHaveTextContent(`Następne sprawdzenie: ${at("2026-09-24T13:00:00Z")}`));
    expect(within(paused).getByRole("switch")).toHaveAttribute("aria-checked", "true");
  });

  it("nieudana pauza zostawia regułę aktywną i opisuje błąd", async () => {
    server.on(`POST /api/v1/automations/${RULE_ID}/pause`, () => apiError(409, "stale_version"));
    const user = userEvent.setup();
    renderPage();
    const active = await screen.findByRole("listitem", { name: "Pilne zgłoszenia" });

    await user.click(within(active).getByRole("switch"));

    expect(await within(active).findByRole("alert")).toHaveTextContent(/zmieniła się w międzyczasie/);
    expect(within(active).getByRole("switch")).toHaveAttribute("aria-checked", "true");
  });

  it("„Sprawdź teraz” kolejkuje skan aktywnej reguły albo opisuje 409", async () => {
    let busy = false;
    server.on(`POST /api/v1/automations/${RULE_ID}/check`, () =>
      busy
        ? apiError(409, "scan_in_progress")
        : ((busy = true), json({ status: "accepted", rule_id: RULE_ID, scan_id: "scan-7" }, 202)),
    );
    const user = userEvent.setup();
    renderPage();
    const active = await screen.findByRole("listitem", { name: "Pilne zgłoszenia" });

    expect(within(row("Szkic reguły")).queryByRole("button", { name: "Sprawdź teraz" })).toBeNull();
    await user.click(within(active).getByRole("button", { name: "Sprawdź teraz" }));
    expect(await within(active).findByText(/Zakolejkowano sprawdzenie/)).toBeInTheDocument();
    await user.click(within(active).getByRole("button", { name: "Sprawdź teraz" }));
    expect(await within(active).findByText("Sprawdzenie już trwa.")).toBeInTheDocument();
  });
});
