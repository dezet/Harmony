import { expect, test } from "@playwright/test";

test("overview renders React data from REST and channel", async ({ page }) => {
  await page.goto("/");

  await expect(page.getByRole("heading", { name: "Overview" })).toBeVisible();
  await expect(page.getByText("COD-1")).toBeVisible();
  await expect(page.getByText("Live")).toBeVisible();

  await page.request.post("/api/v1/refresh");
  await expect(page.getByText("COD-2")).toBeVisible();
});

test("projects route is owned by the React router", async ({ page }) => {
  await page.goto("/projects");

  await expect(page.getByRole("heading", { name: "Projects", exact: true })).toBeVisible();
  await expect(page.getByRole("main").getByRole("link", { name: "New project" })).toBeVisible();
});

test("runtime route is owned by the React router", async ({ page }) => {
  await page.goto("/runtime");

  await expect(page.getByRole("heading", { name: "Runtime" })).toBeVisible();
});
