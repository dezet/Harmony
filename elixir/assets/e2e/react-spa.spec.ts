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

test("sidebar project link navigates to the workspace", async ({ page }) => {
  await page.goto("/");

  // Wait for the sidebar project to appear (derived from the snapshot entry)
  const projectLink = page.getByRole("link", { name: /react-spa-e2e/i });
  await expect(projectLink).toBeVisible();

  await projectLink.click();

  await expect(page).toHaveURL(/\/projects\/react-spa-e2e$/);

  // Workspace header shows the slug
  await expect(page.getByRole("heading", { level: 1, name: "react-spa-e2e" })).toBeVisible();

  // Evidence tab is present but disabled
  const evidenceTab = page.getByRole("button", { name: "Evidence" });
  await expect(evidenceTab).toBeVisible();
  await expect(evidenceTab).toBeDisabled();

  // Running column heading is visible (card title — exact match to avoid the counts line)
  await expect(page.getByText("Running", { exact: true })).toBeVisible();
});
