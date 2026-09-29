import type { APIRequestContext, Page } from "@playwright/test";
import { expect, test } from "./support";

// Rule editor (T27.7, T27.8 conflict): 15 min, one priority, both channels,
// save → preview → confirmed activation, against the real controllers of
// the E2E server and its synthetic Jira/Linear stubs. That the preview alone
// has no effects is asserted by the backend test
// `SymphonyElixir.IntakeApiTest` — "preview reads the saved rule, returns at
// most 20 samples and writes nothing" (test/symphony_elixir/intake_api_test.exs).

test.use({ viewport: { width: 1440, height: 1050 } });

const RULE_NAME = "Pilne zgłoszenia HR (E2E)";

async function csrfToken(request: APIRequestContext): Promise<string> {
  const response = await request.get("/api/v1/csrf");
  expect(response.ok()).toBe(true);
  return ((await response.json()) as { csrf_token: string }).csrf_token;
}

async function ruleById(request: APIRequestContext, id: string) {
  const response = await request.get(`/api/v1/automations/${id}`);
  expect(response.ok()).toBe(true);
  return ((await response.json()) as { rule: Record<string, unknown> }).rule;
}

function ruleIdOf(page: Page): string {
  const match = /\/automations\/([0-9a-f-]{36})$/.exec(new URL(page.url()).pathname);
  expect(match, "rule editor URL").not.toBeNull();
  return match![1];
}

test("new rule: 15 min, one priority, both channels → save → preview → confirmed activation", async ({ page }) => {
  await page.goto("/automations");
  await expect(page.getByRole("heading", { level: 1, name: "Automatyzacje" })).toBeVisible();
  await expect(page.getByRole("link", { name: "Pilne zgłoszenia Finanse" })).toBeVisible();
  await page.getByRole("main").getByRole("link", { name: "Nowa reguła" }).first().click();

  await expect(page.getByRole("heading", { level: 1, name: "Nowa reguła" })).toBeVisible();
  await page.getByLabel("Nazwa reguły").fill(RULE_NAME);
  await page.getByLabel("Projekt", { exact: true }).selectOption({ label: "HR" });
  await page.getByLabel("Połączenie Jira").selectOption({ label: "Jira · Harmony E2E" });
  await page.getByRole("radio", { name: "Tablica" }).check();
  await page.getByLabel("Tablica Jira").selectOption({ label: "HR / Wsparcie (ID 43)" });

  await page.getByRole("group", { name: "Szybki wybór" }).getByRole("button", { name: "15 min" }).click();
  await expect(page.getByLabel("Sprawdzaj co")).toHaveValue("15");
  await expect(page.getByText("= 900 s")).toBeVisible();

  await page.getByRole("checkbox", { name: /^Wysoki/ }).check();
  await expect(page.getByRole("checkbox", { name: /^Krytyczny/ })).not.toBeChecked();

  await page.getByLabel("Zespół Linear").selectOption({ label: "Operacje (OPS)" });
  await page.getByLabel("Projekt Linear").selectOption({ label: "Wsparcie" });
  await expect(page.getByLabel("Status początkowy")).toHaveValue("Todo");

  await page.getByRole("checkbox", { name: "Wysyłaj e-mail" }).check();
  await page.getByLabel("Połączenie SMTP").selectOption({ label: "Poczta dyżurna" });
  await page.getByLabel("Adresaci e-mail").fill("hr-dyzur@example.test");
  await page.getByRole("checkbox", { name: "Wysyłaj SMS" }).check();
  await page.getByLabel("Połączenie SMSAPI").selectOption({ label: "SMSAPI dyżur" });
  await page.getByLabel("Numery telefonów").fill("+48 600 100 300");

  // Preview and activation need a saved version first.
  await expect(page.getByRole("button", { name: "Przetestuj na zapisanej wersji" })).toBeDisabled();

  await page.getByRole("button", { name: "Zapisz regułę" }).click();
  await expect(page.getByRole("heading", { level: 1, name: `Reguła: ${RULE_NAME}` })).toBeVisible();
  await expect(page.getByText("Reguła zapisana i pozostaje nieaktywna.")).toBeVisible();

  const id = ruleIdOf(page);
  const saved = await ruleById(page.request, id);
  expect(saved).toMatchObject({
    name: RULE_NAME,
    interval_seconds: 900,
    priority_ids: ["2"],
    source_type: "board",
    source_id: "43",
    email_recipients: ["hr-dyzur@example.test"],
    enabled: false,
    activation_status: "idle",
  });
  expect(saved.email_connection_id).toEqual(expect.any(String));
  expect(saved.sms_connection_id).toEqual(expect.any(String));
  expect(saved.sms_recipients).toEqual([expect.stringMatching(/^\+?48\s?600\s?100\s?300$/)]);

  // Preview of the saved version: no activation, nothing sent.
  await page.getByRole("button", { name: "Przetestuj na zapisanej wersji" }).click();
  const preview = page.getByRole("region", { name: "Wynik podglądu" });
  await expect(preview).toContainText("3 zgłoszenia spełniają teraz warunki.");
  await expect(preview.getByRole("link", { name: "HR-71" })).toHaveAttribute(
    "href",
    "https://harmony-e2e.atlassian.net/browse/HR-71",
  );
  await expect(preview).toContainText("Podgląd niczego nie wysłał");
  expect(await ruleById(page.request, id)).toMatchObject({ enabled: false, activation_status: "idle" });

  // Activation is a separate confirmed step.
  await page.getByRole("button", { name: "Aktywuj regułę" }).click();
  const confirm = page.getByRole("alertdialog", { name: "Aktywować regułę?" });
  await expect(confirm).toBeVisible();
  await confirm.getByRole("button", { name: "Anuluj" }).click();
  await expect(confirm).toBeHidden();
  expect(await ruleById(page.request, id)).toMatchObject({ activation_status: "idle" });

  await page.getByRole("button", { name: "Aktywuj regułę" }).click();
  await confirm.getByRole("button", { name: "Aktywuj regułę" }).click();
  await expect(page.getByText("Trwa skan bazowy.")).toBeVisible();
  // The baseline runs in the scheduler, which the harness never starts.
  expect(await ruleById(page.request, id)).toMatchObject({ enabled: false, activation_status: "activating" });
});

test("a save over a newer server version shows the conflict and keeps the edits", async ({ page, allowConsoleError }) => {
  allowConsoleError(/status of 409/);
  await page.goto("/automations");
  await page.getByRole("link", { name: RULE_NAME }).click();
  await expect(page.getByRole("heading", { level: 1, name: `Reguła: ${RULE_NAME}` })).toBeVisible();
  const id = ruleIdOf(page);

  // Someone else saves the rule in the meantime.
  const current = await ruleById(page.request, id);
  const token = await csrfToken(page.request);
  const patch = await page.request.patch(`/api/v1/automations/${id}`, {
    headers: { "x-csrf-token": token, origin: new URL(page.url()).origin },
    data: { version: current.config_version, name: `${RULE_NAME} — zmiana z innej karty` },
  });
  expect(patch.status()).toBe(200);

  await page.getByLabel("Nazwa reguły").fill(`${RULE_NAME} — moja zmiana`);
  await page.getByRole("button", { name: "Zapisz regułę" }).click();

  const conflict = page.getByRole("alert", { name: "Konflikt wersji" });
  await expect(conflict).toBeVisible();
  await expect(page.getByLabel("Nazwa reguły")).toHaveValue(`${RULE_NAME} — moja zmiana`);
  expect((await ruleById(page.request, id)).name).toBe(`${RULE_NAME} — zmiana z innej karty`);

  await conflict.getByRole("button", { name: "Wczytaj aktualną wersję" }).click();
  await expect(conflict).toBeHidden();
  await expect(page.getByLabel("Nazwa reguły")).toHaveValue(`${RULE_NAME} — zmiana z innej karty`);
});

test("the rule editor is usable by keyboard only", async ({ page }) => {
  await page.goto("/automations");
  await page.getByRole("link", { name: "Pilne zgłoszenia Finanse" }).focus();
  await page.keyboard.press("Enter");
  await expect(page.getByRole("heading", { level: 1, name: "Reguła: Pilne zgłoszenia Finanse" })).toBeVisible();

  // Tab order through the interval field reaches the preset buttons.
  await page.getByLabel("Sprawdzaj co").focus();
  await page.keyboard.press("Tab");
  await expect(page.getByRole("combobox", { name: "Jednostka" })).toBeFocused();
  const fifteen = page.getByRole("group", { name: "Szybki wybór" }).getByRole("button", { name: "15 min" });
  for (let step = 0; step < 8 && !(await fifteen.evaluate((element) => element === document.activeElement)); step++) {
    await page.keyboard.press("Tab");
  }
  await expect(fifteen).toBeFocused();
  expect(await fifteen.evaluate((element) => element.matches(":focus-visible"))).toBe(true);
  await page.keyboard.press("Enter");
  await expect(fifteen).toHaveAttribute("aria-pressed", "true");
  await expect(page.getByLabel("Sprawdzaj co")).toHaveValue("15");

  const pause = page.getByRole("button", { name: "Wstrzymaj regułę" });
  await expect(pause).toBeEnabled();
  expect(await pause.evaluate((element) => element.tabIndex)).toBeGreaterThanOrEqual(0);

  // Leaving with unsaved edits asks first; Escape keeps the edit.
  await page.getByRole("button", { name: "Reguły Jira" }).focus();
  await page.keyboard.press("Enter");
  const leave = page.getByRole("alertdialog", { name: "Porzucić niezapisane zmiany?" });
  await expect(leave).toBeVisible();
  await page.keyboard.press("Escape");
  await expect(leave).toBeHidden();
  await expect(page.getByLabel("Sprawdzaj co")).toHaveValue("15");
});
