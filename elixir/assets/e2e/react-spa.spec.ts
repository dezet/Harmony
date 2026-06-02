import { expect, test } from "@playwright/test";

test("dashboard renders React data from REST and channel", async ({ page }) => {
  await page.goto("/");

  await expect(page.getByRole("heading", { name: "Dashboard" })).toBeVisible();
  await expect(page.getByText("COD-1")).toBeVisible();
  await expect(page.getByText(".harmony/artifacts/react-e2e-1.png")).toBeVisible();
  await expect(page.getByText("Live")).toBeVisible();

  await page.request.post("/api/v1/refresh");
  await expect(page.getByText("COD-2")).toBeVisible();
  await expect(page.getByText(".harmony/artifacts/react-e2e-2.png")).toBeVisible();
});

test("projects route is owned by the React router", async ({ page }) => {
  await page.goto("/projects");

  await expect(page.getByRole("heading", { name: "Projects" })).toBeVisible();
  await expect(page.getByRole("link", { name: "New project" })).toBeVisible();
});
