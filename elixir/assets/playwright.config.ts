import { defineConfig, devices } from "@playwright/test";

const port = Number(process.env.HARMONY_E2E_PORT ?? 4201);

// One worker: every spec shares the seeded server state of one E2E run (a
// single SQL sandbox), so the files run one after another in a fixed order.
export default defineConfig({
  testDir: "./e2e",
  timeout: 30_000,
  workers: 1,
  fullyParallel: false,
  forbidOnly: true,
  retries: 0,
  expect: { timeout: 10_000 },
  use: {
    baseURL: `http://127.0.0.1:${port}`,
    locale: "pl-PL",
    timezoneId: "Europe/Warsaw",
    trace: "retain-on-failure",
    screenshot: "only-on-failure",
  },
  projects: [
    {
      name: "chromium",
      use: { ...devices["Desktop Chrome"] },
    },
  ],
  webServer: {
    command: `cd .. && mix assets.build && mix harmony.react_spa_e2e_server --port ${port}`,
    url: `http://127.0.0.1:${port}`,
    reuseExistingServer: false,
    timeout: 60_000,
  },
});
