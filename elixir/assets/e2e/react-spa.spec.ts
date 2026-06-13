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

  // All four tab buttons are present and enabled
  const evidenceTab = page.getByRole("button", { name: "Evidence" });
  await expect(evidenceTab).toBeVisible();
  await expect(evidenceTab).not.toBeDisabled();

  // Running column heading is visible (card title — exact match to avoid the counts line)
  await expect(page.getByText("Running", { exact: true })).toBeVisible();
});

test("workspace tabs: evidence, activity, and configuration deep-link", async ({ page }) => {
  await page.goto("/projects/react-spa-e2e");

  // Wait for the workspace to load
  await expect(page.getByRole("heading", { level: 1, name: "react-spa-e2e" })).toBeVisible();

  // --- Evidence tab ---
  await page.getByRole("button", { name: "Evidence" }).click();
  await expect(page).toHaveURL(/[?&]tab=evidence/);

  // An artifact group with the COD-1 run identifier should be visible
  await expect(page.getByText("COD-1")).toBeVisible();

  // A screenshot <img> whose src contains the artifact API path
  await expect(
    page.locator('img[src*="/api/v1/artifacts/"]').first(),
  ).toBeVisible();

  // --- Activity tab ---
  await page.getByRole("button", { name: "Activity" }).click();
  await expect(page).toHaveURL(/[?&]tab=activity/);

  // The seeded run_started event should appear in the feed
  await expect(page.getByText("run_started")).toBeVisible();

  // --- Configuration tab ---
  await page.getByRole("button", { name: "Configuration" }).click();
  await expect(page).toHaveURL(/[?&]tab=configuration/);

  // The configuration form should be visible with the slug prefilled
  const slugInput = page.getByLabel("Slug", { exact: true });
  await expect(slugInput).toBeVisible();
  await expect(slugInput).toHaveValue("react-spa-e2e");
});

test("workspace tab deep-link: direct navigation to ?tab=configuration", async ({ page }) => {
  await page.goto("/projects/react-spa-e2e?tab=configuration");

  // Configuration form should load directly with the slug prefilled
  const slugInput = page.getByLabel("Slug", { exact: true });
  await expect(slugInput).toBeVisible();
  await expect(slugInput).toHaveValue("react-spa-e2e");
});

test("clicking a running identifier navigates to run detail", async ({ page }) => {
  // Navigate to the project workspace where the running column is visible
  await page.goto("/projects/react-spa-e2e");

  // Wait for the running column to appear and find the COD-1 link
  const runLink = page.getByRole("link", { name: "COD-1" });
  await expect(runLink).toBeVisible();

  await runLink.click();

  // URL should be the run detail page
  await expect(page).toHaveURL(/\/projects\/react-spa-e2e\/runs\/COD-1$/);

  // h1 shows the identifier
  await expect(page.getByRole("heading", { level: 1, name: "COD-1" })).toBeVisible();

  // Breadcrumb shows the identifier as the current page
  await expect(page.getByRole("navigation", { name: "Breadcrumb" }).getByText("COD-1")).toBeVisible();

  // Stream shows the seeded work_event type
  await expect(page.getByText("run_started")).toBeVisible();

  // Rail Stop button is disabled (wired in Phase 5)
  const stopButton = page.getByRole("button", { name: "Stop" });
  await expect(stopButton).toBeVisible();
  await expect(stopButton).toBeDisabled();
});
