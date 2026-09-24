import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { render, screen, waitFor, within } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { createMemoryRouter, RouterProvider } from "react-router-dom";
import { IntegrationsPage } from "@/features/integrations/IntegrationsPage";
import { makeRule, PROJECT_ID, PROJECTS, SMTP_ID as RULE_SMTP_ID } from "@/test/automationServer";
import {
  apiError,
  defaultConnections,
  installIntegrationServer,
  JIRA_ID,
  json,
  makeConnection,
  NEW_CONNECTION_ID,
  SMS_ID,
  SMTP_ID,
  SMTP_SETTINGS,
  type IntegrationServer,
} from "@/test/integrationServer";
import type { IntegrationConnection } from "@/types/contract";

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/;

let server: IntegrationServer;

function renderPage() {
  const queryClient = new QueryClient({ defaultOptions: { queries: { retry: false }, mutations: { retry: false } } });
  const router = createMemoryRouter(
    [
      { path: "/integrations", element: <IntegrationsPage /> },
      { path: "/projects/:id/edit", element: <p>Edycja projektu</p> },
    ],
    { initialEntries: ["/integrations"] },
  );
  render(
    <QueryClientProvider client={queryClient}>
      <RouterProvider router={router} />
    </QueryClientProvider>,
  );
  return { router };
}

const card = (name: string) => screen.getByRole("region", { name });
const row = (name: string) => screen.getByRole("listitem", { name });
const findRow = (name: string) => screen.findByRole("listitem", { name });

function withConnections(connections: IntegrationConnection[], rules = [makeRule()]) {
  server = installIntegrationServer({ connections, rules });
}

beforeEach(() => {
  server = installIntegrationServer();
});

afterEach(() => {
  vi.restoreAllMocks();
  vi.unstubAllGlobals();
});

describe("IntegrationsPage — layout and states", () => {
  it("shows the four provider cards of layout A in order", async () => {
    renderPage();
    expect(screen.getByRole("heading", { level: 1, name: "Integracje" })).toBeInTheDocument();
    expect(screen.getByText("Połączenia, na których opiera się Twoja automatyzacja.")).toBeInTheDocument();
    await findRow("Jira · Electrum");

    const titles = screen.getAllByRole("heading", { level: 2 }).map((heading) => heading.textContent);
    expect(titles).toEqual(["Jira", "Linear", "E-mail", "SMS"]);
    expect(within(card("Jira")).getByText("Źródło zgłoszeń")).toBeInTheDocument();
    expect(within(card("SMS")).getByText("Powiadomienia dyżurnego")).toBeInTheDocument();
    expect(screen.queryByText(/przykład/)).not.toBeInTheDocument();
  });

  it("shows an empty provider as not configured with an add action", async () => {
    withConnections([makeConnection()]);
    renderPage();
    await findRow("Jira · Electrum");
    expect(within(card("E-mail")).getByText("Nie skonfigurowano")).toBeInTheDocument();
    expect(within(card("E-mail")).getByRole("button", { name: "Dodaj połączenie" })).toBeInTheDocument();
  });

  it("shows a designed error with a retry when the connection list fails (AC17)", async () => {
    server.on("GET /api/v1/integrations", () => apiError(503, "action_unavailable"));
    renderPage();
    const alert = await within(card("Jira")).findByRole("alert");
    expect(alert).toHaveTextContent("Nie udało się wczytać połączeń.");

    server.on("GET /api/v1/integrations", () => json({ items: defaultConnections(), meta: { next_cursor: null } }));
    await userEvent.click(within(alert).getByRole("button", { name: "Spróbuj ponownie" }));
    expect(await findRow("Jira · Electrum")).toBeInTheDocument();
  });

  it("creates a connection from a provider card; it stays disabled until switched on", async () => {
    renderPage();
    await findRow("Jira · Electrum");
    await userEvent.click(within(card("SMS")).getByRole("button", { name: "Dodaj połączenie" }));

    const dialog = await screen.findByRole("dialog", { name: "Nowe połączenie · SMS" });
    await userEvent.type(within(dialog).getByLabelText("Nazwa połączenia"), "SMS zapasowy");
    await userEvent.type(within(dialog).getByLabelText("Nazwa nadawcy SMS"), "Electrum");
    await userEvent.type(within(dialog).getByLabelText("Token SMSAPI"), "token-sms");
    await userEvent.click(within(dialog).getByRole("button", { name: "Zapisz połączenie" }));

    await waitFor(() => expect(screen.queryByRole("dialog")).not.toBeInTheDocument());
    const [post] = server.requests("POST", "/api/v1/integrations");
    expect(post.body).toMatchObject({ kind: "smsapi", name: "SMS zapasowy", settings: { sender: "Electrum" } });
    expect(await screen.findByText(/Połączenie zapisane i wyłączone/)).toBeInTheDocument();
    expect(server.connections.get(NEW_CONNECTION_ID)?.enabled).toBe(false);
  });
});

describe("IntegrationsPage — health without false success (T25.6)", () => {
  it("never shows an unchecked or failed connection as connected and gives a concrete hint", async () => {
    withConnections([
      makeConnection({ health: "unchecked", last_checked_at: null }),
      makeConnection({
        id: SMTP_ID,
        kind: "smtp",
        name: "Poczta dyżurna",
        settings: { ...SMTP_SETTINGS },
        health: "error",
        error_code: "smtp_host_not_allowed",
      }),
      makeConnection({ id: SMS_ID, kind: "smsapi", name: "SMSAPI dyżur", settings: { sender: "Harmony" }, health: "error", error_code: "sms_timeout" }),
    ]);
    renderPage();

    const jira = await findRow("Jira · Electrum");
    expect(within(jira).getByText("Nie sprawdzono")).toBeInTheDocument();
    expect(within(jira).queryByText("Połączono")).not.toBeInTheDocument();
    expect(jira).toHaveTextContent(/Stan nieznany/);

    const smtp = row("Poczta dyżurna");
    expect(within(smtp).getByText("Błąd połączenia")).toBeInTheDocument();
    expect(smtp).toHaveTextContent(/nie ma na liście dozwolonych hostów SMTP/);

    const sms = row("SMSAPI dyżur");
    expect(within(sms).getByText("Błąd połączenia")).toBeInTheDocument();
    expect(sms).toHaveTextContent(/kod: sms_timeout/);
    expect(screen.queryByText("Połączono")).not.toBeInTheDocument();
  });

  it("shows connected only for a checked, enabled connection with a stored secret", async () => {
    withConnections([
      makeConnection(),
      makeConnection({ id: SMTP_ID, kind: "smtp", name: "Poczta dyżurna", settings: { ...SMTP_SETTINGS }, secret_state: "unset" }),
      makeConnection({ id: SMS_ID, kind: "smsapi", name: "SMSAPI dyżur", settings: { sender: "Harmony" }, enabled: false }),
    ]);
    renderPage();
    expect(within(await findRow("Jira · Electrum")).getByText("Połączono")).toBeInTheDocument();
    expect(within(row("Poczta dyżurna")).getByText("Brak sekretu")).toBeInTheDocument();
    expect(within(row("SMSAPI dyżur")).getByText("Wyłączone")).toBeInTheDocument();
  });
});

describe("IntegrationsPage — Linear through the project (T25.3)", () => {
  it("uses each project's own Linear secret and never creates a Linear connection", async () => {
    server = installIntegrationServer({
      projects: [{ ...PROJECTS[0], tracker_secret: "set", linear_team_key: "POR" }, PROJECTS[1]],
    });
    renderPage();
    await findRow("Jira · Electrum");

    const linear = card("Linear");
    expect(within(linear).queryByRole("button", { name: "Dodaj połączenie" })).not.toBeInTheDocument();
    expect(linear).toHaveTextContent(/nie ma osobnego połączenia/);

    const portal = within(linear).getByRole("listitem", { name: "Portal klienta" });
    expect(portal).toHaveTextContent("Token Linear zapisany w projekcie");
    expect(portal).toHaveTextContent("POR");
    const finance = within(linear).getByRole("listitem", { name: "Finanse" });
    expect(finance).toHaveTextContent(/Projekt nie ma własnego tokenu Linear/);
    expect(within(portal).getByRole("link", { name: "Ustawienia projektu" })).toHaveAttribute(
      "href",
      `/projects/${PROJECT_ID}/edit`,
    );

    expect(server.requests("GET", `/api/v1/projects/${PROJECT_ID}/linear-options`)).toHaveLength(0);
    await userEvent.click(within(portal).getByRole("button", { name: "Sprawdź dostęp" }));
    expect(await within(portal).findByText(/Dostęp do Linear działa/)).toBeInTheDocument();
    expect(server.requests("GET", `/api/v1/projects/${PROJECT_ID}/linear-options`)).toHaveLength(1);
    expect(server.mutations()).toHaveLength(0);
  });

  it("explains a missing Linear token instead of reporting success", async () => {
    server.on(`GET /api/v1/projects/${PROJECT_ID}/linear-options`, () => apiError(503, "missing_linear_api_token"));
    renderPage();
    await findRow("Jira · Electrum");
    const portal = within(card("Linear")).getByRole("listitem", { name: "Portal klienta" });
    await userEvent.click(within(portal).getByRole("button", { name: "Sprawdź dostęp" }));
    expect(await within(portal).findByRole("alert")).toHaveTextContent(/nie ma tokenu Linear/);
  });
});

describe("IntegrationsPage — connection test and test-send (T25.4)", () => {
  it("checks a connection without any send", async () => {
    withConnections([makeConnection({ health: "unchecked", last_checked_at: null })]);
    renderPage();
    const jira = await findRow("Jira · Electrum");

    await userEvent.click(within(jira).getByRole("button", { name: "Sprawdź połączenie" }));
    expect(await within(jira).findByText(/Test nie wysłał żadnej wiadomości/)).toBeInTheDocument();
    await waitFor(() => expect(within(row("Jira · Electrum")).getByText("Połączono")).toBeInTheDocument());

    expect(server.mutations().map((call) => `${call.method} ${call.path}`)).toEqual([
      `POST /api/v1/integrations/${JIRA_ID}/test`,
    ]);
    expect(within(jira).queryByRole("button", { name: "Wyślij test" })).not.toBeInTheDocument();
  });

  it("shows a failed check as a concrete hint, never as connected", async () => {
    // Like the backend, the check result is stored on the connection (without a version bump).
    server.on(`POST /api/v1/integrations/${SMTP_ID}/test`, () => {
      const current = server.connections.get(SMTP_ID)!;
      server.connections.set(SMTP_ID, { ...current, health: "error", error_code: "smtp_tls_failed", last_checked_at: "2026-09-24T12:30:00Z" });
      return json({ health: "error", checked_at: "2026-09-24T12:30:00Z", error_code: "smtp_tls_failed" });
    });
    renderPage();
    const smtp = await findRow("Poczta dyżurna");
    await userEvent.click(within(smtp).getByRole("button", { name: "Sprawdź połączenie" }));
    await waitFor(() => expect(within(smtp).getByRole("status")).toHaveTextContent(/Nie udało się zestawić TLS/));
    expect(within(smtp).getByRole("status")).toHaveTextContent(/Test nie wysłał żadnej wiadomości/);
    await waitFor(() => expect(server.requests("GET", "/api/v1/integrations").length).toBeGreaterThan(1));
    expect(within(row("Poczta dyżurna")).getByText("Błąd połączenia")).toBeInTheDocument();
    expect(within(row("Poczta dyżurna")).queryByText("Połączono")).not.toBeInTheDocument();
    expect(server.connections.get(SMTP_ID)?.lock_version).toBe(1);
  });

  it("sends a test only from its own dialog with a recipient, cost confirmation and a stable Idempotency-Key", async () => {
    let fail = true;
    server.on(`POST /api/v1/integrations/${SMS_ID}/test-send`, () => {
      if (fail) return apiError(503, "action_unavailable");
      return json({ test_delivery: { id: "d1", operation: "sms", status: "pending" } }, 202);
    });
    renderPage();
    const sms = await findRow("SMSAPI dyżur");
    await userEvent.click(within(sms).getByRole("button", { name: "Wyślij test" }));

    const dialog = await screen.findByRole("dialog", { name: "Wyślij wiadomość testową" });
    expect(dialog).toHaveTextContent(/jeden płatny SMS/);
    expect(dialog).toHaveTextContent(/20 SMS na godzinę/);
    const phone = within(dialog).getByLabelText("Numer telefonu odbiorcy");
    const send = within(dialog).getByRole("button", { name: "Wyślij test" });

    await userEvent.type(phone, "600100200");
    await userEvent.click(send);
    expect(phone).toHaveAttribute("aria-invalid", "true");
    expect(within(dialog).getByText(/z prefiksem kraju/)).toBeInTheDocument();
    expect(within(dialog).getByText(/Potwierdź koszt/)).toBeInTheDocument();
    expect(server.requests("POST", `/api/v1/integrations/${SMS_ID}/test-send`)).toHaveLength(0);

    await userEvent.clear(phone);
    await userEvent.type(phone, "+48 600 100 200");
    await userEvent.click(within(dialog).getByRole("checkbox", { name: /Potwierdzam wysłanie/ }));
    await userEvent.click(send);
    expect(await within(dialog).findByRole("alert")).toBeInTheDocument();

    await userEvent.click(send);
    await waitFor(() => expect(server.requests("POST", `/api/v1/integrations/${SMS_ID}/test-send`)).toHaveLength(2));
    const [first, retry] = server.requests("POST", `/api/v1/integrations/${SMS_ID}/test-send`);
    expect(first.body).toEqual({ recipient: "+48 600 100 200", confirmed: true });
    const key = first.headers.get("idempotency-key");
    expect(key).toMatch(UUID);
    expect(retry.headers.get("idempotency-key")).toBe(key);

    // Another recipient is another attempt: a new key.
    await userEvent.clear(phone);
    await userEvent.type(phone, "+48 600 100 201");
    fail = false;
    await userEvent.click(send);
    expect(await within(dialog).findByText(/Przyjęto do wysłania/)).toBeInTheDocument();
    expect(dialog).toHaveTextContent(/nie oznacza doręczenia/);
    const third = server.requests("POST", `/api/v1/integrations/${SMS_ID}/test-send`)[2];
    expect(third.headers.get("idempotency-key")).toMatch(UUID);
    expect(third.headers.get("idempotency-key")).not.toBe(key);

    // A new attempt after success and a reopened dialog both get fresh keys.
    await userEvent.click(within(dialog).getByRole("button", { name: "Nowa próba" }));
    await userEvent.click(within(dialog).getByRole("checkbox", { name: /Potwierdzam wysłanie/ }));
    await userEvent.click(within(dialog).getByRole("button", { name: "Wyślij test" }));
    await waitFor(() => expect(server.requests("POST", `/api/v1/integrations/${SMS_ID}/test-send`)).toHaveLength(4));
    const fourth = server.requests("POST", `/api/v1/integrations/${SMS_ID}/test-send`)[3];
    expect(fourth.headers.get("idempotency-key")).not.toBe(third.headers.get("idempotency-key"));

    await userEvent.click(within(dialog).getByRole("button", { name: "Zamknij" }));
    await waitFor(() => expect(screen.queryByRole("dialog")).not.toBeInTheDocument());
    await userEvent.click(within(row("SMSAPI dyżur")).getByRole("button", { name: "Wyślij test" }));
    const reopened = await screen.findByRole("dialog", { name: "Wyślij wiadomość testową" });
    expect(within(reopened).getByLabelText("Numer telefonu odbiorcy")).toHaveValue("");
    await userEvent.type(within(reopened).getByLabelText("Numer telefonu odbiorcy"), "+48 600 100 201");
    await userEvent.click(within(reopened).getByRole("checkbox", { name: /Potwierdzam wysłanie/ }));
    await userEvent.click(within(reopened).getByRole("button", { name: "Wyślij test" }));
    await waitFor(() => expect(server.requests("POST", `/api/v1/integrations/${SMS_ID}/test-send`)).toHaveLength(5));
    const keys = server.requests("POST", `/api/v1/integrations/${SMS_ID}/test-send`).map((call) => call.headers.get("idempotency-key"));
    expect(new Set(keys).size).toBe(4);
  });

  it("asks for an e-mail recipient for SMTP and explains disabled effects", async () => {
    server.on(`POST /api/v1/integrations/${SMTP_ID}/test-send`, () => apiError(409, "effects_disabled"));
    renderPage();
    const smtp = await findRow("Poczta dyżurna");
    await userEvent.click(within(smtp).getByRole("button", { name: "Wyślij test" }));
    const dialog = await screen.findByRole("dialog", { name: "Wyślij wiadomość testową" });
    expect(dialog).toHaveTextContent(/60 e-maili na godzinę/);

    await userEvent.type(within(dialog).getByLabelText("Adres e-mail odbiorcy"), "dyzur@electrum.pl");
    await userEvent.click(within(dialog).getByRole("checkbox", { name: /Potwierdzam wysłanie/ }));
    await userEvent.click(within(dialog).getByRole("button", { name: "Wyślij test" }));
    expect(await within(dialog).findByRole("alert")).toHaveTextContent(/intake\.effects_enabled/);
  });

  it("blocks a test-send of a disabled connection", async () => {
    withConnections([makeConnection({ id: SMTP_ID, kind: "smtp", name: "Poczta dyżurna", settings: { ...SMTP_SETTINGS }, enabled: false })]);
    renderPage();
    const smtp = await findRow("Poczta dyżurna");
    expect(within(smtp).getByRole("button", { name: "Wyślij test" })).toBeDisabled();
  });
});

describe("IntegrationsPage — clearing a secret and stopped effects (T25.5)", () => {
  it("clears a secret only after a separate confirmation and then shows stopped effects", async () => {
    withConnections(defaultConnections(), [
      makeRule({ email_connection_id: RULE_SMTP_ID, email_recipients: ["a@electrum.pl"], enabled: true }),
    ]);
    renderPage();
    const smtp = await findRow("Poczta dyżurna");

    await userEvent.click(within(smtp).getByRole("button", { name: "Usuń sekret" }));
    const confirm = await screen.findByRole("alertdialog", { name: "Usunąć zapisany sekret?" });
    expect(confirm).toHaveTextContent(/połączenie zostanie wyłączone/);
    expect(confirm).toHaveTextContent(/aktywne reguły/);
    await userEvent.click(within(confirm).getByRole("button", { name: "Anuluj" }));
    await waitFor(() => expect(screen.queryByRole("alertdialog")).not.toBeInTheDocument());
    expect(server.mutations()).toHaveLength(0);

    await userEvent.click(within(row("Poczta dyżurna")).getByRole("button", { name: "Usuń sekret" }));
    const again = await screen.findByRole("alertdialog", { name: "Usunąć zapisany sekret?" });
    await userEvent.click(within(again).getByRole("button", { name: "Usuń sekret i wyłącz" }));

    await waitFor(() => expect(within(row("Poczta dyżurna")).getByText("Brak sekretu")).toBeInTheDocument());
    const [patch] = server.requests("PATCH", `/api/v1/integrations/${SMTP_ID}`);
    expect(patch.body).toEqual({ version: 1, clear_secret: true });

    const cleared = row("Poczta dyżurna");
    expect(cleared).toHaveTextContent(/Efekty zatrzymane/);
    expect(within(cleared).getByRole("switch", { name: "Połączenie Poczta dyżurna włączone" })).toBeDisabled();
    expect(within(cleared).queryByRole("button", { name: "Usuń sekret" })).not.toBeInTheDocument();
  });

  it("shows a disabled connection's stopped effects and the rules that use it", async () => {
    withConnections(
      [makeConnection({ enabled: false }), ...defaultConnections().slice(1)],
      [makeRule({ enabled: true }), makeRule({ id: "55555555-9999-4555-8555-555555555555", name: "Druga" })],
    );
    renderPage();
    const jira = await findRow("Jira · Electrum");
    expect(within(jira).getByText("Wyłączone")).toBeInTheDocument();
    expect(jira).toHaveTextContent(/Efekty zatrzymane/);
    expect(jira).toHaveTextContent(/nie sprawdzają Jira/);
    await waitFor(() => expect(row("Jira · Electrum")).toHaveTextContent(/Korzystają z niego 2 reguły \(1 aktywna\)/));

    await userEvent.click(within(jira).getByRole("switch", { name: "Połączenie Jira · Electrum włączone" }));
    await waitFor(() => expect(within(row("Jira · Electrum")).getByText("Połączono")).toBeInTheDocument());
    const [patch] = server.requests("PATCH", `/api/v1/integrations/${JIRA_ID}`);
    expect(patch.body).toEqual({ version: 1, enabled: true });
  });
});
