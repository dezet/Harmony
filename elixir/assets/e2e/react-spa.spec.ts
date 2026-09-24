import { expect, test } from "./support";

// Kept screens in shell A (AC16): the technical overview moved to
// /overview („Diagnostyka”), the sidebar project opens the Case Center and the
// workspace is one link further, and every run screen stays reachable.

test("diagnostics renders React data from REST and channel", async ({ page }) => {
  await page.goto("/overview");

  await expect(page.getByRole("heading", { level: 1, name: "Diagnostyka" })).toBeVisible();
  await expect(page.getByText("COD-1").first()).toBeVisible();
  await expect(page.getByRole("complementary").getByRole("status")).toHaveText("Połączono");

  const refresh = await page.request.post("/api/v1/refresh");
  expect(refresh.status()).toBe(202);
  await expect(page.getByText(/^COD-([2-9]|\d\d+)$/).first()).toBeVisible();
});

test("projects route is owned by the React router", async ({ page }) => {
  await page.goto("/projects");

  await expect(page.getByRole("heading", { level: 1, name: "Projekty" })).toBeVisible();
  await expect(page.getByRole("main").getByRole("link", { name: "Nowy projekt" })).toBeVisible();
});

test("runtime route is owned by the React router", async ({ page }) => {
  await page.goto("/runtime");

  await expect(page.getByRole("heading", { level: 1, name: "Środowisko uruchomieniowe" })).toBeVisible();
});

test("sidebar project opens the Case Center and the workspace stays one link away", async ({ page }) => {
  await page.goto("/");

  const projectLink = page.getByRole("navigation", { name: "Projekty" }).getByRole("link", { name: /^Portal klienta/ });
  await expect(projectLink).toBeVisible();
  await projectLink.click();
  await expect(page).toHaveURL(/\/\?project=react-spa-e2e$/);
  await expect(page.getByRole("heading", { level: 1, name: "Portal klienta" })).toBeVisible();

  await page.getByRole("link", { name: "Praca agentów i ustawienia" }).click();
  await expect(page).toHaveURL(/\/projects\/react-spa-e2e$/);
  await expect(page.getByRole("heading", { level: 1, name: "Portal klienta" })).toBeVisible();
  await expect(page.getByText(/^react-spa-e2e · /)).toBeVisible();

  // All four tabs are present and enabled.
  for (const name of ["Praca", "Dowody", "Aktywność", "Konfiguracja"]) {
    await expect(page.getByRole("tab", { name })).toBeEnabled();
  }
  await expect(page.getByText("Przebiegi w toku", { exact: true })).toBeVisible();
});

test("workspace tabs: evidence, activity, and configuration deep-link", async ({ page }) => {
  await page.goto("/projects/react-spa-e2e");
  await expect(page.getByRole("heading", { level: 1, name: "Portal klienta" })).toBeVisible();

  // --- Evidence tab ---
  await page.getByRole("tab", { name: "Dowody" }).click();
  await expect(page).toHaveURL(/[?&]tab=evidence/);
  // The EvidenceTab renders the identifier as a <span>; scope to it so COD-1
  // links still unmounting from the Work tab do not confuse the assertion.
  await expect(page.locator("span.font-mono").filter({ hasText: "COD-1" }).first()).toBeVisible();
  await expect(page.locator('img[src*="/api/v1/artifacts/"]').first()).toBeVisible();

  // --- Activity tab ---
  await page.getByRole("tab", { name: "Aktywność" }).click();
  await expect(page).toHaveURL(/[?&]tab=activity/);
  // Raw event types stay verbatim.
  await expect(page.getByText("run_started")).toBeVisible();

  // --- Configuration tab ---
  await page.getByRole("tab", { name: "Konfiguracja" }).click();
  await expect(page).toHaveURL(/[?&]tab=configuration/);
  const slugInput = page.getByLabel("Slug", { exact: true });
  await expect(slugInput).toBeVisible();
  await expect(slugInput).toHaveValue("react-spa-e2e");
});

test("workspace tab deep-link: direct navigation to ?tab=configuration", async ({ page }) => {
  await page.goto("/projects/react-spa-e2e?tab=configuration");

  const slugInput = page.getByLabel("Slug", { exact: true });
  await expect(slugInput).toBeVisible();
  await expect(slugInput).toHaveValue("react-spa-e2e");
});

test("the agent-work case links to its run detail", async ({ page }) => {
  await page.goto("/?project=react-spa-e2e&q=COD-1");
  await page.getByRole("region", { name: "Lista spraw" }).getByRole("button", { name: /Synchronizacja statusów/ }).click();
  const detail = page.getByRole("region", { name: "Szczegóły sprawy" });
  await expect(detail.getByText("Istniejąca praca agenta", { exact: true })).toBeVisible();
  await expect(detail.getByRole("button", { name: "Zobacz w Jira" })).toBeDisabled();
  await detail.getByRole("tab", { name: "Zgłoszenie" }).click();
  await detail.getByRole("link", { name: "Szczegół przebiegu" }).click();
  await expect(page).toHaveURL(/\/projects\/react-spa-e2e\/runs\/COD-1$/);
  await expect(page.getByRole("heading", { level: 1, name: "COD-1" })).toBeVisible();
});

test("clicking a running identifier navigates to run detail", async ({ page }) => {
  await page.goto("/projects/react-spa-e2e");

  // COD-1 may appear both in the running column and in the history table;
  // both navigate to the same URL.
  const runLink = page.getByRole("link", { name: "COD-1" }).first();
  await expect(runLink).toBeVisible();
  await runLink.click();

  await expect(page).toHaveURL(/\/projects\/react-spa-e2e\/runs\/COD-1$/);
  await expect(page.getByRole("heading", { level: 1, name: "COD-1" })).toBeVisible();
  await expect(page.getByRole("navigation", { name: "Ścieżka" }).getByText("COD-1")).toBeVisible();
  await expect(page.getByText("run_started")).toBeVisible();

  const stopButton = page.getByRole("button", { name: "Zatrzymaj ten przebieg" });
  await expect(stopButton).toBeVisible();
  await expect(stopButton).toBeEnabled();
});

test("stop action: confirm dialog and success toast", async ({ page }) => {
  await page.goto("/projects/react-spa-e2e/runs/COD-1");
  await expect(page.getByRole("heading", { level: 1, name: "COD-1" })).toBeVisible();

  const stopButton = page.getByRole("button", { name: "Zatrzymaj ten przebieg" });
  await expect(stopButton).toBeEnabled();
  await stopButton.click();

  const dialog = page.getByRole("alertdialog", { name: "Zatrzymać ten przebieg?" });
  await expect(dialog).toBeVisible();
  // Soft stop: the copy never promises to kill the OS process.
  await expect(dialog).not.toContainText(/zabi/i);
  await dialog.getByRole("button", { name: "Zatrzymaj przebieg" }).click();

  // The snapshot orchestrator returns :ok → HTTP 200 → success toast.
  await expect(page.getByText("Zażądano zatrzymania przebiegu")).toBeVisible();
});

// The harness itself: a console error or an uncaught page error fails a test.
// `test.fail` inverts the result, so this passes only while the guard works.
test.describe("console guard", () => {
  test.fail();

  test("fails on console.error", async ({ page }) => {
    await page.goto("/projects");
    await page.evaluate(() => console.error("E2E guard probe"));
  });

  test("fails on an uncaught page error", async ({ page }) => {
    await page.goto("/projects");
    // An inline script, not a timer: the frozen clock owns the timers.
    await Promise.all([
      page.waitForEvent("pageerror"),
      page.addScriptTag({ content: 'throw new Error("E2E guard probe");' }),
    ]);
  });
});
