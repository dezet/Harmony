import { mkdirSync } from "node:fs";
import { fileURLToPath } from "node:url";
import type { Locator, Page } from "@playwright/test";
import {
  PROJECT_COLORS,
  caseDetail,
  caseList,
  expect,
  expectNoHorizontalOverflow,
  openCaseCenter,
  settleAnimations,
  sidebarProjects,
  test,
} from "./support";

// Visual regression of layout A (T27.4, T27.5, T27.9).
//
// Every check here is a computed-style, layout, overflow, focus or text
// assertion that passes without any baseline. The screenshots are only
// CANDIDATES for a human to compare with the accepted mockup A: they are
// written to the untracked `output/verification/m6/screenshots/` of the
// worktree, never compared automatically and never updated with
// `--update-snapshots`.

const SCREENSHOTS = fileURLToPath(new URL("../../../output/verification/m6/screenshots/", import.meta.url));
mkdirSync(SCREENSHOTS, { recursive: true });

const VIEWPORTS = [
  { width: 1440, height: 1050, sidebar: 218, boardColumns: 4 },
  { width: 1024, height: 900, sidebar: 185, boardColumns: 2 },
  { width: 768, height: 1024, sidebar: null, boardColumns: 2 },
  { width: 390, height: 844, sidebar: null, boardColumns: 1 },
] as const;

type Variant = { dark: boolean; reduced: boolean };

const DARK_BACKGROUND = "rgb(21, 22, 27)";
const LIGHT_BACKGROUND = "rgb(248, 249, 251)";

function fileName(screen: string, size: { width: number; height: number }, variant: Variant): string {
  return `${SCREENSHOTS}${screen}-${size.width}x${size.height}${variant.dark ? "-dark" : ""}${variant.reduced ? "-reduced" : ""}.png`;
}

async function prepare(page: Page, variant: Variant): Promise<void> {
  await page.emulateMedia({ reducedMotion: variant.reduced ? "reduce" : "no-preference" });
  if (variant.dark) {
    await page.addInitScript(() => window.localStorage.setItem("theme", "dark"));
  }
}

async function expectTheme(page: Page, variant: Variant): Promise<void> {
  await expect(page.locator("html")).toHaveClass(variant.dark ? /\bdark\b/ : /^(?!.*\bdark\b)/);
  expect(await page.evaluate(() => getComputedStyle(document.body).backgroundColor)).toBe(
    variant.dark ? DARK_BACKGROUND : LIGHT_BACKGROUND,
  );
}

// Screens are captured without a stray keyboard focus ring (the focus
// screenshots keep theirs) and after every transition has finished.
async function capture(
  page: Page,
  screen: string,
  size: { width: number; height: number },
  variant: Variant,
  { keepFocus = false }: { keepFocus?: boolean } = {},
) {
  if (!keepFocus) {
    await page.evaluate(() => {
      const active = document.activeElement;
      if (active instanceof HTMLElement && !active.closest('[role="dialog"]')) active.blur();
    });
  }
  await settleAnimations(page);
  await page.screenshot({ path: fileName(screen, size, variant), animations: "disabled", caret: "hide" });
}

async function gridColumns(locator: Locator): Promise<number> {
  return locator.evaluate((element) => getComputedStyle(element).gridTemplateColumns.split(" ").filter(Boolean).length);
}

const VARIANTS: Variant[] = [
  { dark: false, reduced: false },
  { dark: true, reduced: false },
  { dark: false, reduced: true },
];

for (const size of VIEWPORTS) {
  for (const variant of VARIANTS) {
    const label = `${size.width}×${size.height}${variant.dark ? " dark" : ""}${variant.reduced ? " reduced motion" : ""}`;

    test.describe(label, () => {
      test.use({ viewport: { width: size.width, height: size.height } });

      test("Case Center list, detail and Kanban of layout A", async ({ page }) => {
        await prepare(page, variant);
        await openCaseCenter(page, "?project=finanse");
        await expectTheme(page, variant);
        await expect(caseList(page).getByText("30 spraw")).toBeVisible();
        await expectNoHorizontalOverflow(page);

        const desktopNav = page.getByRole("navigation", { name: "Główna" });
        const hamburger = page.getByRole("button", { name: "Otwórz menu" });
        if (size.sidebar === null) {
          await expect(desktopNav).toBeHidden();
          await expect(hamburger).toBeVisible();
        } else {
          await expect(hamburger).toBeHidden();
          const width = await page.getByRole("complementary").evaluate((element) => element.getBoundingClientRect().width);
          expect(width).toBe(size.sidebar);
        }

        const phone = size.width <= 600;
        if (phone) {
          // No permanent detail panel and no auto-opened dialog on a phone.
          await expect(caseDetail(page)).toHaveCount(0);
          await expect(page.getByRole("dialog")).toHaveCount(0);
        } else {
          await expect(caseDetail(page).getByRole("heading", { level: 2 })).toBeVisible();
        }
        await capture(page, "list", size, variant);

        // Detail: the desktop panel, or the dialog on a phone.
        await caseList(page).getByRole("button", { name: /Płatności kartą odrzucane/ }).click();
        const detail = phone ? page.getByRole("dialog", { name: "Szczegóły sprawy" }) : caseDetail(page);
        await expect(detail.getByRole("heading", { name: "Płatności kartą odrzucane po aktualizacji bramki" })).toBeVisible();
        await expect(detail.getByRole("link", { name: "Zobacz w Jira" })).toBeVisible();
        await expectNoHorizontalOverflow(page);
        await capture(page, "detail", size, variant);
        if (phone) {
          await page.keyboard.press("Escape");
          await expect(detail).toBeHidden();
        }

        await page.getByRole("group", { name: "Widok spraw" }).getByRole("button", { name: "Kanban" }).click();
        if (!phone) {
          const dialog = page.getByRole("dialog", { name: "Szczegóły sprawy" });
          await expect(dialog).toBeVisible();
          await page.keyboard.press("Escape");
          await expect(dialog).toBeHidden();
        }
        const board = page.locator('[data-slot="board-columns"]');
        await expect(board.getByRole("region")).toHaveCount(4);
        await expect(board.getByRole("region", { name: "Do decyzji" }).getByRole("listitem")).toHaveCount(25);
        expect(await gridColumns(board)).toBe(size.boardColumns);
        await expectNoHorizontalOverflow(page);
        await capture(page, "kanban", size, variant);
      });

      test("rule form, integrations and diagnostics", async ({ page }) => {
        await prepare(page, variant);

        await page.goto("/automations");
        await page.getByRole("link", { name: "Pilne zgłoszenia Finanse" }).click();
        await expect(page.getByRole("heading", { level: 1, name: "Reguła: Pilne zgłoszenia Finanse" })).toBeVisible();
        await expect(page.getByLabel("Tablica Jira")).toHaveValue("42");
        await expect(page.getByLabel("Zespół Linear")).not.toHaveValue("");
        await expectTheme(page, variant);
        await expectNoHorizontalOverflow(page);
        await capture(page, "rule", size, variant);

        await page.goto("/integrations");
        await expect(page.getByRole("listitem", { name: "Jira · Harmony E2E", exact: true })).toBeVisible();
        await expectNoHorizontalOverflow(page);
        await capture(page, "integrations", size, variant);

        await page.goto("/overview");
        await expect(page.getByRole("heading", { level: 1, name: "Diagnostyka" })).toBeVisible();
        await expect(page.getByText("COD-1").first()).toBeVisible();
        await expectNoHorizontalOverflow(page);
        await capture(page, "diagnostics", size, variant);
      });

      if (size.sidebar === null) {
        test("mobile menu behind the hamburger", async ({ page }) => {
          await prepare(page, variant);
          await openCaseCenter(page);
          const hamburger = page.getByRole("button", { name: "Otwórz menu" });
          await hamburger.focus();
          await page.keyboard.press("Enter");
          const menu = page.getByRole("dialog", { name: "Menu nawigacji" });
          await expect(menu.getByRole("navigation", { name: "Projekty" })).toBeVisible();
          await expectNoHorizontalOverflow(page);
          await capture(page, "menu", size, variant);
          // Focus stays inside the open menu (focus trap). Base UI moves focus
          // off its hidden focus guards asynchronously, so each step waits for
          // the focus to settle on a real element.
          for (let step = 0; step < 15; step++) {
            await page.keyboard.press("Tab");
            await expect
              .poll(() =>
                menu.evaluate((element) => {
                  const active = document.activeElement;
                  if (active?.hasAttribute("data-base-ui-focus-guard")) return "guard";
                  return element.contains(active) ? "inside" : `outside: ${active?.outerHTML.slice(0, 80)}`;
                }),
              )
              .toBe("inside");
          }
          await page.keyboard.press("Escape");
          await expect(menu).toBeHidden();
          await expect(hamburger).toBeFocused();
        });
      }
    });
  }
}

// Hover and keyboard focus of the three project colors (spec §4.2, AC03).
for (const reduced of [false, true]) {
  test.describe(`project colors 1440×1050${reduced ? " reduced motion" : ""}`, () => {
    test.use({ viewport: { width: 1440, height: 1050 } });

    const PROJECTS = [
      { name: "Portal klienta", color: "purple" },
      { name: "Finanse", color: "gold" },
      { name: "HR", color: "teal" },
    ] as const;

    test("hover and focus paint the whole row in the project color with a white dot", async ({ page }) => {
      await page.emulateMedia({ reducedMotion: reduced ? "reduce" : "no-preference" });
      await openCaseCenter(page);
      const projects = sidebarProjects(page);
      const variant = { dark: false, reduced };

      for (const project of PROJECTS) {
        const link = projects.getByRole("link", { name: new RegExp(`^${project.name}`) });
        const dot = link.locator('[data-slot="project-dot"]');
        const count = link.locator('[data-slot="project-count"]');

        const duration = reduced ? "0s" : "0.2s";
        for (const element of [link, dot, count]) {
          const durations = await element.evaluate((node) => getComputedStyle(node).transitionDuration.split(", "));
          expect(durations.every((value) => value === duration), `${project.name} transition ${durations}`).toBe(true);
        }

        const expectHighlighted = async () => {
          await settleAnimations(page);
          const styles = await link.evaluate((node) => {
            const dotNode = node.querySelector('[data-slot="project-dot"]')!;
            const countNode = node.querySelector('[data-slot="project-count"]')!;
            return {
              background: getComputedStyle(node).backgroundColor,
              color: getComputedStyle(node).color,
              dot: getComputedStyle(dotNode).backgroundColor,
              dotTransform: getComputedStyle(dotNode).transform,
              count: getComputedStyle(countNode).color,
              countBackground: getComputedStyle(countNode).backgroundColor,
            };
          });
          expect(styles.background).toBe(PROJECT_COLORS[project.color]);
          expect(styles.color).toBe("rgb(255, 255, 255)");
          expect(styles.dot).toBe("rgb(255, 255, 255)");
          expect(styles.dotTransform).toBe("matrix(1.15, 0, 0, 1.15, 0, 0)");
          expect(styles.count).toBe("rgb(255, 255, 255)");
          // White at 15 % alpha, whatever color space the browser reports it in.
          expect(styles.countBackground).toMatch(/(255, 255, 255, 0\.15\)|\/ 0\.15\)$)/);
        };

        // Hover.
        await link.hover();
        await expectHighlighted();
        await capture(page, `hover-${project.color}`, { width: 1440, height: 1050 }, variant, { keepFocus: true });

        // Keyboard focus, with the pointer elsewhere.
        await page.mouse.move(1300, 1000);
        await link.focus();
        await page.keyboard.press("Shift+Tab");
        await page.keyboard.press("Tab");
        await expect(link).toBeFocused();
        expect(await link.evaluate((node) => node.matches(":focus-visible"))).toBe(true);
        await expectHighlighted();
        // The focus ring stays visible on top of the color.
        expect(await link.evaluate((node) => getComputedStyle(node).outlineStyle)).not.toBe("none");
        await capture(page, `focus-${project.color}`, { width: 1440, height: 1050 }, variant, { keepFocus: true });
        await link.blur();
      }

      // The active project is marked by aria-current, not only by its tint.
      await projects.getByRole("link", { name: /^HR/ }).click();
      await expect(projects.getByRole("link", { name: /^HR/ })).toHaveAttribute("aria-current", "page");
      await page.mouse.move(1300, 1000);
      await settleAnimations(page);
      const tint = await projects
        .getByRole("link", { name: /^HR/ })
        .evaluate((node) => getComputedStyle(node).backgroundColor);
      expect(tint).not.toBe(PROJECT_COLORS.teal);
      expect(tint).not.toBe("rgba(0, 0, 0, 0)");
    });
  });
}

test.describe("theme toggle", () => {
  test.use({ viewport: { width: 1440, height: 1050 } });

  test("dark mode is reachable by keyboard and keeps layout A", async ({ page }) => {
    await openCaseCenter(page, "?project=finanse");
    const listBox = await caseList(page).boundingBox();
    const toggle = page.getByRole("button", { name: "Włącz tryb ciemny" });
    await toggle.focus();
    await page.keyboard.press("Enter");
    await expectTheme(page, { dark: true, reduced: false });
    await expect(page.getByRole("button", { name: "Włącz tryb jasny" })).toBeFocused();
    // Same layout, other surfaces.
    expect(await caseList(page).boundingBox()).toEqual(listBox);
    await page.keyboard.press("Enter");
    await expectTheme(page, { dark: false, reduced: false });
  });
});
