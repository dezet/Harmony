import type { Page } from "@playwright/test";
import { expect, expectNoHorizontalOverflow, test } from "./support";

// Integrations (T27.8 provider states). The E2E server stubs every provider:
// the healthy Jira site answers, „Jira · Odmowa dostępu” gets 401 and
// „Jira · Limit zapytań” gets 429. A connection check never sends anything.

test.use({ viewport: { width: 1440, height: 1050 } });

function connection(page: Page, name: string) {
  return page.getByRole("listitem", { name, exact: true });
}

test("cards of every provider and the Linear token per project", async ({ page }) => {
  await page.goto("/integrations");
  await expect(page.getByRole("heading", { level: 1, name: "Integracje" })).toBeVisible();
  for (const title of ["Jira", "Linear", "E-mail", "SMS"]) {
    await expect(page.getByRole("region", { name: title, exact: true })).toBeVisible();
  }
  await expect(connection(page, "Jira · Harmony E2E")).toContainText("Połączono");
  await expect(connection(page, "Poczta dyżurna")).toContainText("Sekret: zapisany");
  // Secrets are write-only: no secret value ever reaches the page.
  await expect(page.locator("body")).not.toContainText("synthetic-e2e");
  await expectNoHorizontalOverflow(page);
});

test("connection checks show success, 401 and 429 without sending anything", async ({ page }) => {
  await page.goto("/integrations");

  const healthy = connection(page, "Jira · Harmony E2E");
  await healthy.getByRole("button", { name: "Sprawdź połączenie" }).click();
  await expect(healthy.getByRole("status")).toHaveText("Połączenie działa. Test nie wysłał żadnej wiadomości.");

  const denied = connection(page, "Jira · Odmowa dostępu");
  await denied.getByRole("button", { name: "Sprawdź połączenie" }).click();
  await expect(denied.getByRole("status")).toContainText("Jira odrzuciła token (401/403).");
  await expect(denied).toContainText("Błąd połączenia");

  const limited = connection(page, "Jira · Limit zapytań");
  await limited.getByRole("button", { name: "Sprawdź połączenie" }).click();
  await expect(limited.getByRole("status")).toContainText("Jira ograniczyła liczbę zapytań.");

  const smtp = connection(page, "Poczta dyżurna");
  await smtp.getByRole("button", { name: "Sprawdź połączenie" }).click();
  await expect(smtp.getByRole("status")).toHaveText("Połączenie działa. Test nie wysłał żadnej wiadomości.");
});

test("a timed-out list shows its error and recovers on retry", async ({ page, allowConsoleError }) => {
  allowConsoleError(/net::ERR_TIMED_OUT/);
  await page.route("**/api/v1/integrations*", (route) => route.abort("timedout"));
  await page.goto("/integrations");
  await expect(page.getByText("Nie udało się wczytać połączeń.").first()).toBeVisible();

  await page.unroute("**/api/v1/integrations*");
  await page.getByRole("region", { name: "Jira", exact: true }).getByRole("button", { name: "Spróbuj ponownie" }).click();
  await expect(connection(page, "Jira · Harmony E2E")).toBeVisible();
});

test("test-send asks for a recipient and the cost and reports the disabled intake", async ({ page, allowConsoleError }) => {
  allowConsoleError(/status of 409/);
  await page.goto("/integrations");
  const sms = connection(page, "SMSAPI dyżur");
  await sms.getByRole("button", { name: "Wyślij test" }).click();
  const dialog = page.getByRole("dialog", { name: "Wyślij wiadomość testową" });
  await expect(dialog).toBeVisible();

  // Without recipient and cost confirmation nothing is sent.
  await dialog.getByRole("button", { name: "Wyślij test" }).click();
  await expect(dialog.getByLabel("Numer telefonu odbiorcy")).toHaveAttribute("aria-invalid", "true");

  // The harness boots with intake disabled, so the server refuses the send.
  await dialog.getByLabel("Numer telefonu odbiorcy").fill("+48600100200");
  await dialog.getByRole("checkbox", { name: /Potwierdzam wysłanie prawdziwego, płatnego SMS-a/ }).check();
  await dialog.getByRole("button", { name: "Wyślij test" }).click();
  await expect(dialog.getByRole("alert")).toContainText("Obsługa zgłoszeń jest wyłączona w konfiguracji Harmony");
  await page.keyboard.press("Escape");
  await expect(dialog).toBeHidden();
  await expect(sms.getByRole("button", { name: "Wyślij test" })).toBeFocused();
});
