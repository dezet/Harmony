import { expect, test as base, type Page } from "@playwright/test";

// Shared harness of the browser E2E suite:
// - the browser clock is frozen at the "now" of the seeded server data
//   (`IntakeSeed.base_time/0`), so ages and schedules are deterministic;
// - every request that leaves the Harmony origin is answered locally, so no
//   test ever reaches Jira, Linear or any other external host;
// - a test fails on `pageerror` and on `console.error`, unless the test
//   declared the message as the expected result of a fault it injected.

export const BASE_TIME = new Date("2026-09-22T12:00:00.000Z");

export const PROJECT_COLORS = {
  purple: "rgb(120, 102, 181)",
  gold: "rgb(150, 109, 36)",
  teal: "rgb(57, 126, 107)",
} as const;

interface HarnessFixtures {
  /** Declares a console error that an injected fault is expected to produce. */
  allowConsoleError: (pattern: RegExp) => void;
  /** URLs outside the Harmony origin that the page tried to open. */
  externalRequests: string[];
}

export const test = base.extend<HarnessFixtures>({
  externalRequests: async ({ context, baseURL }, provide) => {
    const requests: string[] = [];
    await context.route(
      (url) => !url.href.startsWith(baseURL ?? "http://127.0.0.1"),
      (route) => {
        requests.push(route.request().url());
        return route.fulfill({
          status: 200,
          contentType: "text/html; charset=utf-8",
          body: "<!doctype html><title>Zewnętrzny adres</title><p>Adres zewnętrzny zablokowany w E2E.</p>",
        });
      },
    );
    await provide(requests);
  },

  allowConsoleError: [
    async ({ page, externalRequests }, provide) => {
      void externalRequests;
      const allowed: RegExp[] = [];
      const errors: string[] = [];

      await page.clock.setFixedTime(BASE_TIME);
      page.on("pageerror", (error) => errors.push(`pageerror: ${error.message}`));
      page.on("console", (message) => {
        if (message.type() !== "error") return;
        const text = message.text();
        if (!allowed.some((pattern) => pattern.test(text))) errors.push(`console.error: ${text}`);
      });

      await provide((pattern) => allowed.push(pattern));

      expect(errors, "the page logged errors").toEqual([]);
    },
    { auto: true },
  ],
});

export { expect };

/** No horizontal page scroll (spec §4.5). */
export async function expectNoHorizontalOverflow(page: Page): Promise<void> {
  const { scrollWidth, clientWidth } = await page.evaluate(() => ({
    scrollWidth: document.documentElement.scrollWidth,
    clientWidth: document.documentElement.clientWidth,
  }));
  expect(scrollWidth, "document scrollWidth must not exceed clientWidth").toBeLessThanOrEqual(clientWidth);
}

/** The Case Center with its data loaded. */
export async function openCaseCenter(page: Page, search = ""): Promise<void> {
  await page.goto(`/${search}`);
  await expect(page.getByRole("region", { name: "Podsumowanie spraw" })).toBeVisible();
}

/** Waits until every CSS transition and animation of the document has finished. */
export async function settleAnimations(page: Page): Promise<void> {
  await page.evaluate(async () => {
    await Promise.all(document.getAnimations().map((animation) => animation.finished.catch(() => undefined)));
  });
}

export const caseList = (page: Page) => page.getByRole("region", { name: "Lista spraw" });
export const caseDetail = (page: Page) => page.getByRole("region", { name: "Szczegóły sprawy" });
export const sidebarProjects = (page: Page) => page.getByRole("navigation", { name: "Projekty" });
