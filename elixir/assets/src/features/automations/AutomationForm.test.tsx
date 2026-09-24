import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { render, screen, waitFor, within } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { createMemoryRouter, RouterProvider } from "react-router-dom";
import { AutomationFormPage } from "@/features/automations/AutomationFormPage";
import { AutomationsPage } from "@/features/automations/AutomationsPage";
import {
  automationFormSchema,
  emptyFormValues,
  formValuesFromRule,
  parseIntervalSeconds,
  rulePatch,
  splitInterval,
  toRuleInput,
  type AutomationFormValues,
} from "@/features/automations/automationSchema";
import {
  apiError,
  HOLD_LABEL_ID,
  installAutomationServer,
  JIRA_ID,
  json,
  LINEAR_OPTIONS,
  LINEAR_PROJECT_ID,
  LINEAR_PROJECT_NO_LABEL_ID,
  makePreview,
  makeRule,
  NEW_RULE_ID,
  OTHER_PROJECT_ID,
  PRIORITIES,
  PROJECT_ID,
  RULE_ID,
  SMS_ID,
  SMTP_ID,
  TEAM_ID,
  TEAM_NO_LABEL_ID,
  TEAM_NO_TODO_ID,
  TODO_STATE_ID,
  type AutomationServer,
} from "@/test/automationServer";

type User = ReturnType<typeof userEvent.setup>;

let server: AutomationServer;

function renderAt(path: string) {
  const queryClient = new QueryClient({
    defaultOptions: { queries: { retry: false }, mutations: { retry: false } },
  });
  const router = createMemoryRouter(
    [
      { path: "/automations", element: <AutomationsPage /> },
      { path: "/automations/new", element: <AutomationFormPage /> },
      { path: "/automations/:id", element: <AutomationFormPage /> },
    ],
    { initialEntries: [path] },
  );
  render(
    <QueryClientProvider client={queryClient}>
      <RouterProvider router={router} />
    </QueryClientProvider>,
  );
  return { router, queryClient };
}

async function selectWhenLoaded(user: User, label: string, value: string) {
  const select = screen.getByLabelText(label) as HTMLSelectElement;
  await waitFor(() => expect([...select.options].some((option) => option.value === value)).toBe(true));
  await user.selectOptions(select, value);
}

async function fillNewRule(user: User) {
  await user.type(await screen.findByLabelText("Nazwa reguły"), "Pilne portalu");
  await selectWhenLoaded(user, "Projekt", PROJECT_ID);
  await selectWhenLoaded(user, "Połączenie Jira", JIRA_ID);
  await selectWhenLoaded(user, "Tablica Jira", "42");
  await user.click(await screen.findByRole("checkbox", { name: /Krytyczny/ }));
  await user.click(screen.getByRole("checkbox", { name: /Wysoki/ }));
  await user.click(screen.getByRole("button", { name: "5 min" }));
  await selectWhenLoaded(user, "Zespół Linear", TEAM_ID);
  await selectWhenLoaded(user, "Projekt Linear", LINEAR_PROJECT_ID);
}

async function openRule(path = `/automations/${RULE_ID}`) {
  const view = renderAt(path);
  await screen.findByRole("heading", { level: 1, name: /Reguła: Pilne zgłoszenia/ });
  const board = screen.getByLabelText("Tablica Jira") as HTMLSelectElement;
  await within(board).findByRole("option", { name: "Wsparcie / Portal klienta (ID 42)" });
  expect(board.value).toBe("42");
  return view;
}

const saveButton = () => screen.getByRole("button", { name: "Zapisz regułę" });
const previewButton = () => screen.getByRole("button", { name: "Przetestuj na zapisanej wersji" });
const activateButton = () => screen.getByRole("button", { name: "Aktywuj regułę" });

beforeEach(() => {
  server = installAutomationServer([makeRule()]);
});

afterEach(() => {
  vi.unstubAllGlobals();
});

describe("T24.1 zapis i podgląd nie wywołują efektów", () => {
  it("zapis nowej reguły wysyła jawny RuleInput i nie włącza reguły", async () => {
    const user = userEvent.setup();
    const { router } = renderAt("/automations/new");

    await fillNewRule(user);
    await user.click(saveButton());

    await waitFor(() => expect(router.state.location.pathname).toBe(`/automations/${NEW_RULE_ID}`));
    const posts = server.requests("POST", "/api/v1/automations");
    expect(posts).toHaveLength(1);
    expect(posts[0].body).toEqual({
      name: "Pilne portalu",
      project_id: PROJECT_ID,
      jira_connection_id: JIRA_ID,
      source_type: "board",
      source_id: "42",
      priority_ids: ["1", "2"],
      interval_seconds: 300,
      initial_policy: "new_matches_only",
      linear_team_id: TEAM_ID,
      linear_project_id: LINEAR_PROJECT_ID,
      linear_todo_state_id: TODO_STATE_ID,
      linear_hold_label_id: HOLD_LABEL_ID,
      email_connection_id: null,
      sms_connection_id: null,
      email_recipients: [],
      sms_recipients: [],
    });
    expect(server.mutations().map((call) => call.path)).toEqual(["/api/v1/automations"]);
    expect(await screen.findByText(/Reguła zapisana i pozostaje nieaktywna/)).toBeInTheDocument();
    expect(screen.getByRole("switch", { name: "Reguła aktywna" })).toHaveAttribute("aria-checked", "false");
  });

  it("podgląd używa zapisanej wersji i nie wywołuje activate ani check", async () => {
    const user = userEvent.setup();
    await openRule();

    await user.click(previewButton());

    expect(await screen.findByText(/2 zgłoszenia spełniają teraz warunki/)).toBeInTheDocument();
    expect(server.mutations().map((call) => call.path)).toEqual([`/api/v1/automations/${RULE_ID}/preview`]);
    expect(server.requests("POST", `/api/v1/automations/${RULE_ID}/preview`)[0].body).toEqual({});
    expect(screen.getByText(/Podgląd niczego nie wysłał/)).toBeInTheDocument();
  });

  it("podgląd jest niedostępny, dopóki formularz ma niezapisane zmiany", async () => {
    const user = userEvent.setup();
    await openRule();

    await user.type(screen.getByLabelText("Nazwa reguły"), " v2");

    expect(previewButton()).toBeDisabled();
    expect(previewButton()).toHaveAccessibleDescription(/Zapisz zmiany/);
  });
});

describe("T24.2 pickery Jira i Linear z jawnymi ID", () => {
  it("tablice pokazują ID, doczytują stronę cursorem i szukają po q od początku", async () => {
    const user = userEvent.setup();
    await openRule();
    const board = screen.getByLabelText("Tablica Jira");

    expect(within(board).getByRole("option", { name: "Wsparcie / Portal klienta (ID 42)" })).toBeInTheDocument();
    await user.click(screen.getByRole("button", { name: "Wczytaj więcej tablic" }));
    expect(await within(board).findByRole("option", { name: "HR / Wsparcie (ID 44)" })).toBeInTheDocument();
    const boardsPath = `/api/v1/integrations/${JIRA_ID}/jira/boards`;
    expect(server.requests("GET", boardsPath).at(-1)?.search.get("cursor")).toBe("boards-2");

    await user.type(screen.getByLabelText("Szukaj tablicy"), "finanse");
    await waitFor(() => expect(server.requests("GET", boardsPath).at(-1)?.search.get("q")).toBe("finanse"));
    expect(server.requests("GET", boardsPath).at(-1)?.search.get("cursor")).toBeNull();
  });

  it("błąd pobrania tablic pokazuje ponowienie", async () => {
    let failures = 1;
    server.on(`GET /api/v1/integrations/${JIRA_ID}/jira/boards`, () =>
      failures-- > 0
        ? apiError(503, "jira_rate_limited")
        : json({ items: [{ id: "42", name: "Wsparcie / Portal klienta" }], meta: { next_cursor: null } }),
    );
    const user = userEvent.setup();
    renderAt(`/automations/${RULE_ID}`);

    expect(await screen.findByText("Nie udało się pobrać tablic z Jira.")).toBeInTheDocument();
    expect(screen.getByText(/Jira ograniczyła liczbę zapytań/)).toBeInTheDocument();
    await user.click(screen.getByRole("button", { name: "Ponów pobieranie tablic" }));

    expect(
      await within(screen.getByLabelText("Tablica Jira")).findByRole("option", { name: "Wsparcie / Portal klienta (ID 42)" }),
    ).toBeInTheDocument();
  });

  it("zapisany filtr jest osobnym źródłem z jawnym ID", async () => {
    const user = userEvent.setup();
    await openRule();

    await user.click(screen.getByRole("radio", { name: "Zapisany filtr" }));

    const filter = screen.getByLabelText("Filtr Jira");
    expect(await within(filter).findByRole("option", { name: "Pilne portalu (ID 10010)" })).toBeInTheDocument();
    expect((filter as HTMLSelectElement).value).toBe("");
  });

  it("priorytety są w kolejności Jira z ID, a błąd pobrania ma ponowienie", async () => {
    let failures = 1;
    server.on(`GET /api/v1/integrations/${JIRA_ID}/jira/priorities`, () =>
      failures-- > 0 ? apiError(503, "jira_unavailable") : json({ items: PRIORITIES, meta: { next_cursor: null } }),
    );
    const user = userEvent.setup();
    renderAt(`/automations/${RULE_ID}`);

    expect(await screen.findByText("Nie udało się pobrać priorytetów z Jira.")).toBeInTheDocument();
    await user.click(screen.getByRole("button", { name: "Ponów pobieranie priorytetów" }));

    const boxes = await screen.findAllByRole("checkbox", { name: /ID \d/ });
    expect(boxes.map((box) => box.getAttribute("value"))).toEqual(["1", "2", "3"]);
    expect(screen.getByRole("checkbox", { name: /Krytyczny/ })).toHaveAccessibleName(/ID 1/);
    expect(screen.getByRole("checkbox", { name: /Krytyczny/ })).toBeChecked();
    expect(screen.getByRole("checkbox", { name: /Średni/ })).not.toBeChecked();
  });

  it("Linear pokazuje stan Todo zespołu po ID, a brak Todo blokuje zapis", async () => {
    const user = userEvent.setup();
    await openRule();

    expect(await screen.findByText(`ID stanu: ${TODO_STATE_ID}`)).toBeInTheDocument();
    await user.selectOptions(screen.getByLabelText("Zespół Linear"), TEAM_NO_TODO_ID);

    expect(screen.getByText(/Zespół Finanse nie ma stanu o nazwie Todo/)).toBeInTheDocument();
    await user.click(saveButton());
    expect(await screen.findByText("Wybrany zespół nie ma stanu Todo.")).toBeInTheDocument();
    expect(server.requests("PATCH", `/api/v1/automations/${RULE_ID}`)).toHaveLength(0);
  });

  it("brakującą etykietę ochronną tworzy dopiero po potwierdzeniu", async () => {
    const user = userEvent.setup();
    await openRule();

    await user.selectOptions(screen.getByLabelText("Zespół Linear"), TEAM_NO_LABEL_ID);
    await user.click(screen.getByRole("button", { name: "Utwórz etykietę ochronną" }));

    const dialog = await screen.findByRole("alertdialog");
    expect(within(dialog).getByText(/harmony:analysis-only/)).toBeInTheDocument();
    expect(server.requests("POST", `/api/v1/projects/${PROJECT_ID}/linear-hold-label`)).toHaveLength(0);
    await user.click(within(dialog).getByRole("button", { name: "Utwórz etykietę" }));

    await waitFor(() =>
      expect(server.requests("POST", `/api/v1/projects/${PROJECT_ID}/linear-hold-label`)[0]?.body).toEqual({
        team_id: TEAM_NO_LABEL_ID,
        confirmed: true,
      }),
    );
    expect(await screen.findByText("ID etykiety: 77777777-0000-4777-8777-777777777777")).toBeInTheDocument();
  });

  it("błąd opcji Linear pokazuje ponowienie, a projekt Linear należy do zespołu", async () => {
    let failures = 1;
    server.on(`GET /api/v1/projects/${PROJECT_ID}/linear-options`, () =>
      failures-- > 0 ? apiError(503, "linear_unavailable") : json(LINEAR_OPTIONS),
    );
    const user = userEvent.setup();
    renderAt(`/automations/${RULE_ID}`);

    expect(await screen.findByText("Nie udało się pobrać opcji Linear.")).toBeInTheDocument();
    await user.click(screen.getByRole("button", { name: "Ponów pobieranie opcji Linear" }));

    const project = await screen.findByLabelText("Projekt Linear");
    await waitFor(() => expect((project as HTMLSelectElement).value).toBe(LINEAR_PROJECT_ID));
    expect(within(project).queryByRole("option", { name: /Kadry/ })).toBeNull();
    await user.selectOptions(screen.getByLabelText("Zespół Linear"), TEAM_NO_LABEL_ID);
    expect(within(screen.getByLabelText("Projekt Linear")).getByRole("option", { name: /Kadry/ })).toHaveValue(
      LINEAR_PROJECT_NO_LABEL_ID,
    );
  });
});

describe("T24.3 interwał i granice walidacji", () => {
  it("przelicza jednostki dokładnie, bez cichego zaokrąglania", () => {
    expect(parseIntervalSeconds("5", "minutes")).toEqual({ ok: true, seconds: 300 });
    expect(parseIntervalSeconds("1,5", "minutes")).toEqual({ ok: true, seconds: 90 });
    expect(parseIntervalSeconds("1.1", "minutes")).toEqual({ ok: true, seconds: 66 });
    expect(parseIntervalSeconds("24", "hours")).toEqual({ ok: true, seconds: 86_400 });
    expect(parseIntervalSeconds("0.5", "minutes")).toEqual({ ok: true, seconds: 30 });
    expect(parseIntervalSeconds("1.0001", "minutes")).toEqual({ ok: false, reason: "fraction" });
    expect(parseIntervalSeconds("90.5", "seconds")).toEqual({ ok: false, reason: "fraction" });
    expect(parseIntervalSeconds("", "seconds")).toEqual({ ok: false, reason: "empty" });
    expect(parseIntervalSeconds("1e3", "seconds")).toEqual({ ok: false, reason: "invalid" });
    expect(parseIntervalSeconds("-5", "minutes")).toEqual({ ok: false, reason: "invalid" });

    expect(splitInterval(300)).toEqual({ value: "5", unit: "minutes" });
    expect(splitInterval(3600)).toEqual({ value: "1", unit: "hours" });
    expect(splitInterval(5400)).toEqual({ value: "90", unit: "minutes" });
    expect(splitInterval(90)).toEqual({ value: "90", unit: "seconds" });
  });

  function errorsOf(patch: Partial<AutomationFormValues>): Record<string, string> {
    const values = { ...formValuesFromRule(makeRule()), ...patch };
    try {
      automationFormSchema.validateSync(values, { abortEarly: false });
      return {};
    } catch (error) {
      const inner = (error as { inner: { path: string; message: string }[] }).inner;
      return Object.fromEntries(inner.map((entry) => [entry.path.replace(/\[\d+\]$/, ""), entry.message]));
    }
  }

  it("sprawdza granice 60–86400 s, nazwy, priorytetów i ID źródła", () => {
    expect(errorsOf({})).toEqual({});
    expect(errorsOf({ interval_value: "59", interval_unit: "seconds" })).toHaveProperty("interval_value");
    expect(errorsOf({ interval_value: "60", interval_unit: "seconds" })).toEqual({});
    expect(errorsOf({ interval_value: "0.5", interval_unit: "minutes" }).interval_value).toMatch(/co najmniej 60 s/);
    expect(errorsOf({ interval_value: "86400", interval_unit: "seconds" })).toEqual({});
    expect(errorsOf({ interval_value: "86401", interval_unit: "seconds" }).interval_value).toMatch(/najwyżej 86 400 s/);
    expect(errorsOf({ interval_value: "1.0001", interval_unit: "minutes" }).interval_value).toMatch(/pełnej liczby sekund/);

    expect(errorsOf({ name: "" })).toHaveProperty("name");
    expect(errorsOf({ name: "   " })).toHaveProperty("name");
    expect(errorsOf({ name: "a".repeat(100) })).toEqual({});
    expect(errorsOf({ name: "a".repeat(101) }).name).toMatch(/100 znaków/);

    const many = Array.from({ length: 101 }, (_, index) => String(index + 1));
    expect(errorsOf({ priority_ids: [] }).priority_ids).toMatch(/co najmniej jeden priorytet/);
    expect(errorsOf({ priority_ids: many.slice(0, 100) })).toEqual({});
    expect(errorsOf({ priority_ids: many }).priority_ids).toMatch(/100/);
    expect(errorsOf({ priority_ids: ["1", "1"] }).priority_ids).toMatch(/powtarzać/);
    expect(errorsOf({ priority_ids: ["1a"] })).toHaveProperty("priority_ids");

    expect(errorsOf({ source_id: "" })).toHaveProperty("source_id");
    expect(errorsOf({ source_id: "4a" }).source_id).toMatch(/cyfr/);
  });

  it("wysyła dokładną liczbę sekund i blokuje zapis wartości ułamkowej", async () => {
    const user = userEvent.setup();
    await openRule();
    const interval = screen.getByLabelText("Sprawdzaj co");

    await user.clear(interval);
    await user.type(interval, "1,0001");
    await user.click(saveButton());
    expect(await screen.findByText(/pełnej liczby sekund/)).toBeInTheDocument();
    expect(interval).toHaveAccessibleDescription(/pełnej liczby sekund/);
    expect(server.requests("PATCH", `/api/v1/automations/${RULE_ID}`)).toHaveLength(0);

    await user.clear(interval);
    await user.type(interval, "1,5");
    expect(screen.getByText("= 90 s")).toBeInTheDocument();
    await user.click(saveButton());
    await waitFor(() =>
      expect(server.requests("PATCH", `/api/v1/automations/${RULE_ID}`)[0]?.body).toEqual({
        version: 1,
        interval_seconds: 90,
      }),
    );
  });

  it("wczytuje interwał w największej jednostce, która dzieli go bez reszty", async () => {
    server.rules.set(RULE_ID, makeRule({ interval_seconds: 90 }));
    await openRule();

    expect(screen.getByLabelText("Sprawdzaj co")).toHaveValue("90");
    expect(screen.getByLabelText("Jednostka")).toHaveValue("seconds");
    expect(screen.getByRole("button", { name: "1 min" })).toHaveAttribute("aria-pressed", "false");
  });
});

describe("T24.4 odbiorcy SMTP i SMSAPI", () => {
  function errorsOf(patch: Partial<AutomationFormValues>): Record<string, string> {
    const values = { ...formValuesFromRule(makeRule()), ...patch };
    try {
      automationFormSchema.validateSync(values, { abortEarly: false });
      return {};
    } catch (error) {
      const inner = (error as { inner: { path: string; message: string }[] }).inner;
      return Object.fromEntries(inner.map((entry) => [entry.path, entry.message]));
    }
  }

  it("kanał włączony wymaga połączenia i 1–10 poprawnych adresatów", () => {
    const tenMails = Array.from({ length: 10 }, (_, index) => `dyzur${index}@example.test`).join("\n");
    expect(errorsOf({ email_enabled: true, email_connection_id: SMTP_ID, email_recipients: "" }).email_recipients).toMatch(
      /co najmniej jednego/,
    );
    expect(errorsOf({ email_enabled: true, email_connection_id: "", email_recipients: "a@example.test" })).toHaveProperty(
      "email_connection_id",
    );
    expect(errorsOf({ email_enabled: true, email_connection_id: SMTP_ID, email_recipients: tenMails })).toEqual({});
    expect(
      errorsOf({ email_enabled: true, email_connection_id: SMTP_ID, email_recipients: `${tenMails}\nx@example.test` })
        .email_recipients,
    ).toMatch(/najwyżej 10/);
    expect(
      errorsOf({ email_enabled: true, email_connection_id: SMTP_ID, email_recipients: "to-nie-adres" }).email_recipients,
    ).toMatch(/to-nie-adres/);
    expect(errorsOf({ sms_enabled: true, sms_connection_id: SMS_ID, sms_recipients: "600100200" }).sms_recipients).toMatch(
      /prefiks/,
    );
    expect(errorsOf({ sms_enabled: true, sms_connection_id: SMS_ID, sms_recipients: "+48 600 100 200" })).toEqual({});
  });

  it("kanał wyłączony wysyła null i pustą listę, nawet gdy pole było wypełnione", () => {
    const values: AutomationFormValues = {
      ...formValuesFromRule(makeRule()),
      email_enabled: false,
      email_connection_id: SMTP_ID,
      email_recipients: "dyzur@example.test",
      sms_enabled: true,
      sms_connection_id: SMS_ID,
      sms_recipients: "+48 600 100 200\n\n+48 600 100 201",
    };
    expect(errorsOf(values)).toEqual({});
    const input = toRuleInput(values);
    expect(input.email_connection_id).toBeNull();
    expect(input.email_recipients).toEqual([]);
    expect(input.sms_connection_id).toBe(SMS_ID);
    expect(input.sms_recipients).toEqual(["+48 600 100 200", "+48 600 100 201"]);
  });

  it("odrzucenie numeru przez backend (422) jest pokazane przy polu", async () => {
    server.on(`PATCH /api/v1/automations/${RULE_ID}`, () =>
      apiError(422, "validation_failed", { sms_recipients: ["must contain E.164 phone numbers"] }),
    );
    const user = userEvent.setup();
    await openRule();

    await user.click(screen.getByRole("checkbox", { name: "Wysyłaj SMS" }));
    await selectWhenLoaded(user, "Połączenie SMSAPI", SMS_ID);
    await user.type(screen.getByLabelText("Numery telefonów"), "+48 600 100 200");
    await user.click(saveButton());

    expect(await screen.findByRole("alert", { name: "Nie zapisano reguły" })).toBeInTheDocument();
    expect(screen.getByLabelText("Numery telefonów")).toHaveAccessibleDescription(/format międzynarodowy z prefiksem kraju/);
  });

  it("formularz zapisuje jawnych adresatów obu kanałów", async () => {
    const user = userEvent.setup();
    await openRule();

    await user.click(screen.getByRole("checkbox", { name: "Wysyłaj e-mail" }));
    await selectWhenLoaded(user, "Połączenie SMTP", SMTP_ID);
    await user.type(screen.getByLabelText("Adresaci e-mail"), "dyzur@example.test");
    await user.click(screen.getByRole("checkbox", { name: "Wysyłaj SMS" }));
    await selectWhenLoaded(user, "Połączenie SMSAPI", SMS_ID);
    await user.click(saveButton());

    expect(await screen.findByText("Podaj co najmniej jednego adresata SMS.")).toBeInTheDocument();
    expect(screen.getByLabelText("Numery telefonów")).toHaveAccessibleDescription(/co najmniej jednego adresata SMS/);
    await user.type(screen.getByLabelText("Numery telefonów"), "+48 600 100 200");
    await user.click(saveButton());

    await waitFor(() =>
      expect(server.requests("PATCH", `/api/v1/automations/${RULE_ID}`)[0]?.body).toEqual({
        version: 1,
        email_connection_id: SMTP_ID,
        email_recipients: ["dyzur@example.test"],
        sms_connection_id: SMS_ID,
        sms_recipients: ["+48 600 100 200"],
      }),
    );
  });
});

describe("T24.5 podgląd prostym językiem", () => {
  it("opisuje regułę, liczbę dopasowań, politykę bazową i kolizje", async () => {
    server.on(`POST /api/v1/automations/${RULE_ID}/preview`, () =>
      json(
        makePreview(makeRule(), {
          match_count: 57,
          truncated: true,
          warnings: [
            { code: "already_linked", count: 3 },
            { code: "source_conflict", rules: [{ rule_id: "r-other", project_id: OTHER_PROJECT_ID }] },
          ],
        }),
      ),
    );
    const user = userEvent.setup();
    await openRule();

    const summary = screen.getByTestId("rule-summary");
    await waitFor(() =>
      expect(summary).toHaveTextContent(
        "Co 5 min sprawdzaj tablicę Wsparcie / Portal klienta. Gdy zgłoszenie pierwszy raz otrzyma priorytet Krytyczny lub Wysoki, utwórz sprawę i rozpocznij analizę.",
      ),
    );
    expect(screen.getByText("Nie wysyłaj powiadomień.")).toBeInTheDocument();

    await user.click(previewButton());

    expect(await screen.findByText(/57 zgłoszeń spełnia teraz warunki/)).toBeInTheDocument();
    expect(screen.getByText("Pokazano pierwsze 2 z 57.")).toBeInTheDocument();
    expect(screen.getByText(/zostaną zapisane jako stan początkowy/)).toBeInTheDocument();
    expect(screen.getByText(/3 z nich mają już sprawę w Harmony/)).toBeInTheDocument();
    expect(screen.getByRole("alert", { name: "Kolizja źródła" })).toHaveTextContent(/Finanse/);
    expect(screen.getByRole("link", { name: /OPS-142/ })).toHaveAttribute(
      "href",
      "https://electrum.atlassian.net/browse/OPS-142",
    );
  });

  it("dla importu istniejących podaje liczbę zgłoszeń, które dostaną efekty", async () => {
    server.rules.set(RULE_ID, makeRule({ initial_policy: "include_existing" }));
    server.on(`POST /api/v1/automations/${RULE_ID}/preview`, () =>
      json(
        makePreview(makeRule({ initial_policy: "include_existing" }), {
          warnings: [
            { code: "already_linked", count: 1 },
            { code: "include_existing_import", count: 1 },
          ],
        }),
      ),
    );
    const user = userEvent.setup();
    await openRule();

    await user.click(previewButton());

    expect(await screen.findByText(/Aktywacja zaimportuje 1 zgłoszenie jako nową sprawę/)).toBeInTheDocument();
  });

  it("błąd podglądu jest opisany po polsku", async () => {
    server.on(`POST /api/v1/automations/${RULE_ID}/preview`, () => apiError(422, "scan_limit_exceeded"));
    const user = userEvent.setup();
    await openRule();

    await user.click(previewButton());

    expect(await screen.findByText(/Źródło zwraca zbyt wiele zgłoszeń/)).toBeInTheDocument();
  });
});

describe("T24.6 aktywacja wymaga zapisu i potwierdzenia", () => {
  it("aktywuje dopiero po potwierdzeniu, z wersją zapisanej konfiguracji", async () => {
    const user = userEvent.setup();
    await openRule();

    await user.click(activateButton());
    const dialog = await screen.findByRole("alertdialog", { name: "Aktywować regułę?" });
    expect(within(dialog).getByText(/pełny skan bazowy/)).toBeInTheDocument();
    expect(server.requests("POST", `/api/v1/automations/${RULE_ID}/activate`)).toHaveLength(0);

    await user.click(within(dialog).getByRole("button", { name: "Aktywuj regułę" }));

    await waitFor(() =>
      expect(server.requests("POST", `/api/v1/automations/${RULE_ID}/activate`)[0]?.body).toEqual({
        version: 1,
        confirmed: true,
      }),
    );
    expect(await screen.findByText(/Trwa skan bazowy/, { selector: "[role=status] *, [role=status]" })).toBeInTheDocument();
    expect(server.requests("POST", `/api/v1/automations/${RULE_ID}/check`)).toHaveLength(0);
  });

  it("niezapisane zmiany blokują aktywację i ostrzegają przed opuszczeniem edycji", async () => {
    const user = userEvent.setup();
    const { router } = await openRule();

    await user.type(screen.getByLabelText("Nazwa reguły"), " v2");
    expect(activateButton()).toBeDisabled();
    expect(activateButton()).toHaveAccessibleDescription(/Zapisz zmiany/);

    await user.click(screen.getByRole("button", { name: "Reguły Jira" }));
    const dialog = await screen.findByRole("alertdialog", { name: "Porzucić niezapisane zmiany?" });
    await user.click(within(dialog).getByRole("button", { name: "Zostań w edycji" }));
    expect(router.state.location.pathname).toBe(`/automations/${RULE_ID}`);
    expect(screen.getByLabelText("Nazwa reguły")).toHaveValue("Pilne zgłoszenia v2");

    await user.click(screen.getByRole("button", { name: "Reguły Jira" }));
    await user.click(
      within(await screen.findByRole("alertdialog")).getByRole("button", { name: "Porzuć zmiany" }),
    );
    await waitFor(() => expect(router.state.location.pathname).toBe("/automations"));
  });

  it("import istniejących wymaga podglądu przed aktywacją", async () => {
    server.rules.set(RULE_ID, makeRule({ initial_policy: "include_existing" }));
    const user = userEvent.setup();
    await openRule();

    expect(activateButton()).toBeDisabled();
    expect(activateButton()).toHaveAccessibleDescription(/Najpierw uruchom podgląd/);
    await user.click(previewButton());
    await screen.findByText(/spełniają teraz warunki/);
    await user.click(activateButton());

    const dialog = await screen.findByRole("alertdialog");
    expect(within(dialog).getByText(/zaimportuje/)).toBeInTheDocument();
  });

  it("odrzucenie aktywacji 422 pokazuje polskie powody przy polach", async () => {
    server.on(`POST /api/v1/automations/${RULE_ID}/activate`, () =>
      apiError(422, "linear_todo_state_mismatch", {
        linear_todo_state_id: ["linear_todo_state_mismatch"],
        priority_ids: ["jira_priority_unknown"],
        analysis_profile: ["analysis_profile_unavailable"],
        public_url: ["some_future_code"],
      }),
    );
    const user = userEvent.setup();
    await openRule();

    await user.click(activateButton());
    await user.click(within(await screen.findByRole("alertdialog")).getByRole("button", { name: "Aktywuj regułę" }));

    const alert = await screen.findByRole("alert", { name: "Reguły nie aktywowano" });
    expect(alert).toHaveTextContent(/Zapisany stan Todo nie odpowiada/);
    expect(alert).toHaveTextContent(/Profil analizy nie jest skonfigurowany/);
    expect(alert).toHaveTextContent(/Warunek aktywacji nie jest spełniony/);
    expect(screen.getByRole("group", { name: "Priorytety" })).toHaveAccessibleDescription(
      /Co najmniej jeden priorytet nie istnieje już w Jira/,
    );
    expect(screen.getByRole("switch", { name: "Reguła aktywna" })).toHaveAttribute("aria-checked", "false");
  });

  it("wyłączone efekty zewnętrzne (409) są opisane przy akcji", async () => {
    server.on(`POST /api/v1/automations/${RULE_ID}/activate`, () => apiError(409, "effects_disabled"));
    const user = userEvent.setup();
    await openRule();

    await user.click(activateButton());
    await user.click(within(await screen.findByRole("alertdialog")).getByRole("button", { name: "Aktywuj regułę" }));

    expect(await screen.findByRole("alert", { name: "Reguły nie aktywowano" })).toHaveTextContent(
      /Efekty zewnętrzne są wyłączone/,
    );
  });
});

describe("T24.7 konflikt wersji nie nadpisuje cudzej konfiguracji", () => {
  it("409 zachowuje moje zmiany i proponuje wczytanie aktualnej wersji", async () => {
    const user = userEvent.setup();
    await openRule();
    server.rules.set(RULE_ID, makeRule({ name: "Zmienione przez kogoś", config_version: 2 }));

    await user.clear(screen.getByLabelText("Nazwa reguły"));
    await user.type(screen.getByLabelText("Nazwa reguły"), "Moja nazwa");
    await user.click(saveButton());

    const alert = await screen.findByRole("alert", { name: "Konflikt wersji" });
    expect(alert).toHaveTextContent(/Ktoś zmienił tę regułę/);
    expect(server.requests("PATCH", `/api/v1/automations/${RULE_ID}`)).toHaveLength(1);
    expect(server.requests("PATCH", `/api/v1/automations/${RULE_ID}`)[0].body).toEqual({ version: 1, name: "Moja nazwa" });
    expect(screen.getByLabelText("Nazwa reguły")).toHaveValue("Moja nazwa");
    expect(server.rules.get(RULE_ID)?.name).toBe("Zmienione przez kogoś");

    await user.click(within(alert).getByRole("button", { name: "Wczytaj aktualną wersję" }));
    await waitFor(() => expect(screen.getByLabelText("Nazwa reguły")).toHaveValue("Zmienione przez kogoś"));
    expect(screen.queryByRole("alert", { name: "Konflikt wersji" })).toBeNull();
  });

  it("po aktywacji nie wysyła pól niezmiennych, a zmiana źródła ostrzega o wyłączeniu", async () => {
    server.rules.set(
      RULE_ID,
      makeRule({
        enabled: true,
        activated_at: "2026-09-20T10:00:00Z",
        baseline_complete_at: "2026-09-20T10:01:00Z",
        next_poll_at: "2026-09-24T12:05:00Z",
      }),
    );
    const user = userEvent.setup();
    await openRule();

    expect(screen.getByRole("radio", { name: "Tylko nowe dopasowania" })).toBeDisabled();
    expect(screen.getByLabelText("Zespół Linear")).toBeDisabled();
    expect(screen.getByLabelText("Projekt")).toBeDisabled();

    await user.click(screen.getByRole("checkbox", { name: /Średni/ }));
    expect(screen.getByText(/Zmiana źródła lub priorytetów wyłączy regułę/)).toBeInTheDocument();
    await user.click(saveButton());

    await waitFor(() =>
      expect(server.requests("PATCH", `/api/v1/automations/${RULE_ID}`)[0]?.body).toEqual({
        version: 1,
        priority_ids: ["1", "2", "3"],
      }),
    );
  });

  it("rulePatch pomija niezmienione pola i kolejność priorytetów", () => {
    const rule = makeRule({ priority_ids: ["2", "1"], activated_at: "2026-09-20T10:00:00Z" });
    const input = toRuleInput({ ...formValuesFromRule(rule), priority_ids: ["1", "2"] });
    expect(rulePatch(rule, input)).toEqual({});
    expect(rulePatch(rule, { ...input, initial_policy: "include_existing", name: "Nowa" })).toEqual({ name: "Nowa" });
    expect(emptyFormValues().interval_value).toBe("5");
  });
});
