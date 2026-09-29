import type { Page } from "@playwright/test";
import {
  caseDetail,
  caseList,
  expect,
  expectNoHorizontalOverflow,
  openCaseCenter,
  sidebarProjects,
  test,
} from "./support";

// Case Center flows (T27.2, T27.3, T27.6) on the deterministic data of the
// E2E server (`IntakeSeed`): Finanse has 30 cases, 27 of them "Do decyzji".

const JIRA_SITE = "https://harmony-e2e.atlassian.net";

function column(page: Page, name: string) {
  return page.getByRole("region", { name, exact: true });
}

test.describe("desktop 1440×1050", () => {
  test.use({ viewport: { width: 1440, height: 1050 } });

  test("all projects → Finanse → list/Kanban → detail → both links → back", async ({ page, externalRequests }) => {
    await openCaseCenter(page);
    await expect(page.getByRole("heading", { level: 1, name: "Centrum spraw" })).toBeVisible();

    const projects = sidebarProjects(page);
    await expect(projects.getByRole("link", { name: "Finanse, 30 spraw", exact: true })).toBeVisible();
    await expect(projects.getByRole("link", { name: "HR, 2 sprawy", exact: true })).toBeVisible();
    await expect(projects.getByRole("link", { name: "Portal klienta, 3 sprawy", exact: true })).toBeVisible();
    await expect(caseList(page).getByText("35 spraw")).toBeVisible();

    const finanse = projects.getByRole("link", { name: /^Finanse/ });
    await finanse.click();
    await expect(page).toHaveURL(/\/\?project=finanse$/);
    await expect(finanse).toHaveAttribute("aria-current", "page");
    await expect(page.getByRole("heading", { level: 1, name: "Finanse" })).toBeVisible();
    await expect(page.getByRole("link", { name: "Praca agentów i ustawienia" })).toHaveAttribute(
      "href",
      "/projects/finanse",
    );

    // Desktop list selects the first result: FIN-140 still waits for Linear.
    const detail = caseDetail(page);
    await expect(detail.getByRole("heading", { level: 2, name: "Import wyciągu bankowego zatrzymuje się na 80%" })).toBeVisible();
    await expect(detail.getByRole("link", { name: "Zobacz w Jira" })).toHaveAttribute("href", `${JIRA_SITE}/browse/FIN-140`);
    const linearDisabled = detail.getByRole("button", { name: "Zobacz w Linear" });
    await expect(linearDisabled).toBeDisabled();
    await expect(linearDisabled).toHaveAccessibleDescription("Zadanie Linear nie zostało jeszcze potwierdzone.");
    await expect(detail.locator('a[href="#"]')).toHaveCount(0);

    await caseList(page).getByRole("button", { name: /Płatności kartą odrzucane/ }).click();
    await expect(page).toHaveURL(/[?&]case=jira_[0-9a-f-]+/);
    await expect(detail.getByRole("heading", { level: 2, name: "Płatności kartą odrzucane po aktualizacji bramki" })).toBeVisible();
    await expect(detail.getByText("Tylko analiza")).toBeVisible();

    const jira = detail.getByRole("link", { name: "Zobacz w Jira" });
    const linear = detail.getByRole("link", { name: "Zobacz w Linear" });
    await expect(jira).toHaveAttribute("href", `${JIRA_SITE}/browse/FIN-142`);
    await expect(linear).toHaveAttribute("href", "https://linear.app/harmony-e2e/issue/OPS-142");
    for (const link of [jira, linear]) {
      await expect(link).toHaveAttribute("target", "_blank");
      await expect(link).toHaveAttribute("rel", "noopener noreferrer");
    }
    // Visually identical link buttons (AC04): same class list and same box height.
    expect(await jira.getAttribute("class")).toBe(await linear.getAttribute("class"));
    expect((await jira.boundingBox())?.height).toBe((await linear.boundingBox())?.height);

    const caseUrl = page.url();
    for (const [link, href] of [
      [jira, `${JIRA_SITE}/browse/FIN-142`],
      [linear, "https://linear.app/harmony-e2e/issue/OPS-142"],
    ] as const) {
      const popupPromise = page.waitForEvent("popup");
      await link.click();
      const popup = await popupPromise;
      await popup.waitForLoadState();
      expect(popup.url()).toBe(href);
      // noopener: the new tab cannot reach the Case Center.
      expect(await popup.evaluate(() => window.opener)).toBeNull();
      await popup.close();
      await page.bringToFront();
      expect(page.url()).toBe(caseUrl);
      await expect(detail.getByRole("heading", { level: 2, name: "Płatności kartą odrzucane po aktualizacji bramki" })).toBeVisible();
    }
    expect(externalRequests).toEqual([`${JIRA_SITE}/browse/FIN-142`, "https://linear.app/harmony-e2e/issue/OPS-142"]);

    // Kanban keeps project and selection; the selected case opens as a dialog.
    await page.getByRole("group", { name: "Widok spraw" }).getByRole("button", { name: "Kanban" }).click();
    await expect(page).toHaveURL(/view=kanban/);
    await expect(page).toHaveURL(/project=finanse/);
    const dialog = page.getByRole("dialog", { name: "Szczegóły sprawy" });
    await expect(dialog.getByRole("heading", { name: "Płatności kartą odrzucane po aktualizacji bramki" })).toBeVisible();
    await page.keyboard.press("Escape");
    await expect(dialog).toBeHidden();

    for (const [name, total] of [
      ["Wykryte", "1"],
      ["W analizie", "1"],
      ["Do decyzji", "27"],
      ["Przekazane", "1"],
    ] as const) {
      await expect(column(page, name).getByText(total, { exact: true })).toBeVisible();
    }

    const card = column(page, "Do decyzji").getByRole("button", { name: /Różnica w sumie faktur/ });
    await card.click();
    await expect(dialog.getByRole("heading", { name: "Różnica w sumie faktur po imporcie" })).toBeVisible();
    await page.keyboard.press("Escape");
    await expect(dialog).toBeHidden();
    await expect(card).toBeFocused();

    // Back to the list and to all projects.
    await page.getByRole("group", { name: "Widok spraw" }).getByRole("button", { name: "Lista" }).click();
    await expect(caseList(page)).toBeVisible();
    // Finanse 27 and Portal klienta 1 case await a decision.
    await page
      .getByRole("navigation", { name: "Główna" })
      .getByRole("link", { name: "Centrum spraw, 28 do decyzji", exact: true })
      .click();
    await expect(page).toHaveURL(/\/$/);
    await expect(page.getByRole("heading", { level: 1, name: "Centrum spraw" })).toBeVisible();
    await expect(caseList(page).getByText("35 spraw")).toBeVisible();
  });

  test("filters, search, Back/Forward and reload keep the URL state", async ({ page }) => {
    await openCaseCenter(page, "?project=finanse");
    const list = caseList(page);
    await expect(list.getByText("30 spraw")).toBeVisible();

    const filters = page.getByRole("group", { name: "Filtr spraw" });
    await filters.getByRole("button", { name: /^Do decyzji/ }).click();
    await expect(page).toHaveURL(/filter=decision/);
    await expect(list.getByText("27 spraw")).toBeVisible();
    await expect(filters.getByRole("button", { name: /^Do decyzji/ })).toHaveAttribute("aria-pressed", "true");

    await filters.getByRole("button", { name: /^Wszystkie/ }).click();
    await expect(list.getByText("30 spraw")).toBeVisible();

    const search = page.getByRole("searchbox", { name: "Szukaj spraw" });
    await search.fill("  raport vat ");
    await expect(page).toHaveURL(/q=raport\+vat/);
    await expect(list.getByText("1 sprawa")).toBeVisible();
    await expect(list.getByRole("button", { name: /Raport VAT za sierpień/ })).toBeVisible();

    // Search by the Jira key as well.
    await search.fill("FIN-137");
    await expect(page).toHaveURL(/q=FIN-137/);
    await expect(list.getByRole("button", { name: /Powiadomienie o zaległej płatności/ })).toBeVisible();
    await expect(list.getByText("1 sprawa")).toBeVisible();

    await filters.getByRole("button", { name: /^Zakończone/ }).click();
    await expect(page.getByText("Nie ma spraw pasujących do filtrów.")).toBeVisible();

    await page.goBack();
    await expect(page).not.toHaveURL(/filter=done/);
    await expect(list.getByRole("button", { name: /Powiadomienie o zaległej płatności/ })).toBeVisible();
    await page.goBack();
    await expect(page).toHaveURL(/q=raport\+vat/);
    await expect(search).toHaveValue("raport vat");
    await expect(list.getByRole("button", { name: /Raport VAT za sierpień/ })).toBeVisible();
    await page.goForward();
    await expect(page).toHaveURL(/q=FIN-137/);
    await page.goForward();
    await expect(page).toHaveURL(/filter=done/);

    await page.reload();
    await expect(page.getByText("Nie ma spraw pasujących do filtrów.")).toBeVisible();
    await expect(search).toHaveValue("FIN-137");
    await expect(filters.getByRole("button", { name: /^Zakończone/ })).toHaveAttribute("aria-pressed", "true");

    await page.getByRole("button", { name: "Wyczyść filtry" }).click();
    await expect(list.getByText("30 spraw")).toBeVisible();

    // An invalid enum is normalized to the default without a new entry.
    await page.goto("/?project=finanse&view=tablica&filter=nic");
    await expect(page).toHaveURL(/\/\?project=finanse$/);
  });

  test("list and every Kanban column page by 25 with their own „Pokaż więcej”", async ({ page }) => {
    await openCaseCenter(page, "?project=finanse");
    const list = caseList(page);
    await expect(list.getByRole("listitem")).toHaveCount(25);
    await list.getByRole("button", { name: "Pokaż więcej" }).click();
    await expect(list.getByRole("listitem")).toHaveCount(30);
    await expect(list.getByRole("button", { name: "Pokaż więcej" })).toHaveCount(0);

    await page.goto("/?project=finanse&view=kanban");
    const decision = column(page, "Do decyzji");
    await expect(decision.getByRole("listitem")).toHaveCount(25);
    await expect(decision.getByText("27", { exact: true })).toBeVisible();
    for (const name of ["Wykryte", "W analizie", "Przekazane"]) {
      await expect(column(page, name).getByRole("listitem")).toHaveCount(1);
      await expect(column(page, name).getByRole("button", { name: "Pokaż więcej" })).toHaveCount(0);
    }
    await decision.getByRole("button", { name: "Pokaż więcej" }).click();
    await expect(decision.getByRole("listitem")).toHaveCount(27);
    await expect(decision.getByRole("button", { name: "Pokaż więcej" })).toHaveCount(0);
    await expect(decision.getByText("27", { exact: true })).toBeVisible();
    await expect(page.getByRole("region", { name: "Podsumowanie spraw" })).toContainText("27");
  });

  test("an unknown project is a 404 with a way back, not all data", async ({ page, allowConsoleError }) => {
    allowConsoleError(/status of 404/);
    await page.goto("/?project=nie-ma-takiego");
    await expect(page.getByRole("heading", { level: 1, name: "Nie znaleziono projektu" })).toBeVisible();
    await page.getByRole("main").getByRole("link", { name: "Centrum spraw" }).click();
    await expect(page.getByRole("heading", { level: 1, name: "Centrum spraw" })).toBeVisible();
  });
});

test.describe("mobile 390×844", () => {
  test.use({ viewport: { width: 390, height: 844 } });

  test("hamburger, project choice, detail dialog, focus restore, no horizontal overflow", async ({ page }) => {
    await openCaseCenter(page);
    await expectNoHorizontalOverflow(page);
    await expect(page.getByRole("navigation", { name: "Projekty" })).toBeHidden();

    const hamburger = page.getByRole("button", { name: "Otwórz menu" });
    await hamburger.click();
    const menu = page.getByRole("dialog", { name: "Menu nawigacji" });
    await expect(menu).toBeVisible();
    await expect(menu.getByRole("link", { name: "HR, 2 sprawy", exact: true })).toBeVisible();
    await expectNoHorizontalOverflow(page);

    // Escape closes the menu and returns focus to the hamburger.
    await page.keyboard.press("Escape");
    await expect(menu).toBeHidden();
    await expect(hamburger).toBeFocused();

    await hamburger.click();
    await menu.getByRole("link", { name: /^HR/ }).click();
    await expect(menu).toBeHidden();
    await expect(page).toHaveURL(/\/\?project=hr$/);
    await expect(page.getByRole("heading", { level: 1, name: "HR" })).toBeVisible();
    await expectNoHorizontalOverflow(page);

    // A phone never opens the detail by itself.
    const dialog = page.getByRole("dialog", { name: "Szczegóły sprawy" });
    await expect(caseList(page).getByText("2 sprawy")).toBeVisible();
    await expect(dialog).toHaveCount(0);

    const item = caseList(page).getByRole("button", { name: /Lista obecności nie uwzględnia/ });
    await item.click();
    await expect(dialog.getByRole("heading", { name: "Lista obecności nie uwzględnia pracy zdalnej" })).toBeVisible();
    await expect(dialog.getByRole("link", { name: "Zobacz w Jira" })).toBeVisible();
    await expectNoHorizontalOverflow(page);

    await dialog.getByRole("tab", { name: "Historia" }).click();
    await expect(dialog.getByText("Wykryto zgłoszenie spełniające regułę")).toBeVisible();

    await dialog.getByRole("button", { name: "Zamknij szczegóły" }).click();
    await expect(dialog).toBeHidden();
    await expect(item).toBeFocused();

    await item.press("Enter");
    await expect(dialog).toBeVisible();
    await page.keyboard.press("Escape");
    await expect(dialog).toBeHidden();
    await expect(item).toBeFocused();
    await expectNoHorizontalOverflow(page);
  });
});

test.describe("visible fault states (T27.8)", () => {
  test.use({ viewport: { width: 1440, height: 1050 } });

  test("403 from the session guard: the action is refused, explained, nothing changes", async ({
    page,
    allowConsoleError,
  }) => {
    allowConsoleError(/status of 403/);
    // A stale token, as after a server restart: the real server rejects it.
    await page.route("**/api/v1/csrf", (route) =>
      route.fulfill({ status: 200, contentType: "application/json", body: JSON.stringify({ csrf_token: "wygasly-token" }) }),
    );
    await openCaseCenter(page, "?project=finanse");
    await caseList(page).getByRole("button", { name: /Płatności kartą odrzucane/ }).click();
    const actions = caseDetail(page).getByRole("group", { name: "Akcje sprawy" });
    await actions.getByRole("button", { name: "Przyjmij sprawę" }).click();
    await expect(actions.getByRole("alert")).toContainText("Zabezpieczenie sesji wygasło i zostało odnowione.");

    const ref = new URL(page.url()).searchParams.get("case");
    const detail = await (await page.request.get(`/api/v1/cases/${ref}`)).json();
    expect(detail.case.acknowledged_at).toBeNull();
    expect(detail.case.column).toBe("decision");
  });

  test("a timed-out case list shows its error, keeps the page and recovers", async ({ page, allowConsoleError }) => {
    allowConsoleError(/net::ERR_TIMED_OUT/);
    await page.route(/\/api\/v1\/cases\?(?!.*page_size=1(&|$))/, (route) => route.abort("timedout"));
    await page.goto("/?project=finanse");
    await expect(caseList(page).getByRole("alert")).toContainText("Nie udało się wczytać spraw.");
    await expect(page.getByRole("heading", { level: 1, name: "Finanse" })).toBeVisible();

    await page.unrouteAll({ behavior: "wait" });
    await caseList(page).getByRole("button", { name: "Spróbuj ponownie" }).click();
    await expect(caseList(page).getByText("30 spraw")).toBeVisible();
  });

  test("offline keeps the last data with a warning and disables mutations; online restores them", async ({
    page,
    context,
    allowConsoleError,
  }) => {
    allowConsoleError(/net::ERR_INTERNET_DISCONNECTED|WebSocket/);
    await openCaseCenter(page, "?project=finanse");
    await caseList(page).getByRole("button", { name: /Płatności kartą odrzucane/ }).click();
    const acknowledge = caseDetail(page).getByRole("button", { name: "Przyjmij sprawę" });
    await expect(acknowledge).toBeEnabled();

    await context.setOffline(true);
    await expect(page.getByRole("alert").filter({ hasText: "Brak połączenia z serwerem." })).toBeVisible();
    await expect(page.getByRole("button", { name: "Sprawdź teraz" })).toBeDisabled();
    await expect(acknowledge).toBeDisabled();
    await expect(caseList(page).getByText("30 spraw")).toBeVisible();

    await context.setOffline(false);
    await expect(page.getByRole("alert").filter({ hasText: "Brak połączenia z serwerem." })).toBeHidden();
    await expect(acknowledge).toBeEnabled();
    await expect(page.getByRole("button", { name: "Sprawdź teraz" })).toBeEnabled();
  });

  test("a dropped socket shows reconnecting and returns to „Połączono”", async ({ page, allowConsoleError }) => {
    allowConsoleError(/WebSocket/);
    let refuse = false;
    const sockets: { close: () => Promise<void> }[] = [];
    await page.routeWebSocket(/\/socket\/websocket/, (ws) => {
      if (refuse) {
        void ws.close();
        return;
      }
      ws.connectToServer();
      sockets.push(ws);
    });

    await openCaseCenter(page, "?project=finanse");
    const state = page.getByRole("complementary").getByRole("status");
    await expect(state).toHaveText("Połączono");

    refuse = true;
    await Promise.all(sockets.map((ws) => ws.close()));
    await expect(state).not.toHaveText("Połączono");
    await expect(page.getByRole("alert").filter({ hasText: "Brak połączenia z serwerem." })).toBeVisible();

    refuse = false;
    await expect(state).toHaveText("Połączono", { timeout: 20_000 });
    await expect(page.getByRole("alert").filter({ hasText: "Brak połączenia z serwerem." })).toBeHidden();
    await expect(caseList(page).getByText("30 spraw")).toBeVisible();
  });

  test("empty results and an empty column have their own states", async ({ page }) => {
    await openCaseCenter(page, "?project=hr&view=kanban");
    await expect(column(page, "W analizie").getByText("Brak spraw na tym etapie.")).toBeVisible();
    await expect(column(page, "Do decyzji").getByText("Brak spraw na tym etapie.")).toBeVisible();

    await page.getByRole("group", { name: "Widok spraw" }).getByRole("button", { name: "Lista" }).click();
    await page.getByRole("searchbox", { name: "Szukaj spraw" }).fill("nie ma takiej sprawy");
    await expect(page.getByText("Nie ma spraw pasujących do filtrów.")).toBeVisible();
    await expect(caseDetail(page)).toContainText("Wybierz sprawę z listy, aby zobaczyć analizę.");
  });
});
