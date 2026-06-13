import { render, screen } from "@testing-library/react";
import { MemoryRouter, Routes, Route } from "react-router-dom";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import { RunDetailPage } from "@/features/run/RunDetailPage";
import detailFixture from "@/test/fixtures/run_detail.fixture.json";
import streamFixture from "@/test/fixtures/run_stream_page.fixture.json";

// ─── Mock socket/channel so useRunChannel does not throw ─────────────────────

vi.mock("@/lib/socket", () => ({
  getSocket: () => ({
    channel: () => ({
      on: () => 0,
      join: () => ({ receive: () => ({ receive: () => undefined }) }),
      leave: vi.fn(() => ({ receive: () => undefined })),
    }),
  }),
}));

// ─── Helpers ─────────────────────────────────────────────────────────────────

function makeFetch(
  detailResponse: Response | (() => Response),
  streamResponse: Response | (() => Response),
) {
  return vi.fn(async (input: string | URL | Request) => {
    const url = typeof input === "string" ? input : input instanceof URL ? input.href : input.url;
    if (url.includes("/stream")) {
      return typeof streamResponse === "function" ? streamResponse() : streamResponse;
    }
    return typeof detailResponse === "function" ? detailResponse() : detailResponse;
  });
}

function jsonResponse(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json" },
  });
}

function renderAt(path: string) {
  const qc = new QueryClient({ defaultOptions: { queries: { retry: false } } });
  return render(
    <QueryClientProvider client={qc}>
      <MemoryRouter initialEntries={[path]}>
        <Routes>
          <Route
            path="/projects/:slug/runs/:identifier"
            element={<RunDetailPage />}
          />
        </Routes>
      </MemoryRouter>
    </QueryClientProvider>,
  );
}

beforeEach(() => {
  vi.stubGlobal(
    "fetch",
    makeFetch(
      jsonResponse(detailFixture),
      jsonResponse(streamFixture),
    ),
  );
});

afterEach(() => vi.restoreAllMocks());

// ─── Tests ────────────────────────────────────────────────────────────────────

describe("RunDetailPage", () => {
  describe("success state", () => {
    it("renders the identifier in a heading", async () => {
      renderAt("/projects/alpha/runs/COD-10");
      const heading = await screen.findByRole("heading", { level: 1 });
      expect(heading).toHaveTextContent("COD-10");
    });

    it("renders the status badge from the fixture", async () => {
      renderAt("/projects/alpha/runs/COD-10");
      // status = "running" in the detail fixture; may appear in both header and rail
      const badges = await screen.findAllByText("running");
      expect(badges.length).toBeGreaterThan(0);
    });

    it("renders a stream item type from the stream fixture", async () => {
      renderAt("/projects/alpha/runs/COD-10");
      // First item type in the stream fixture is "turn_start"
      expect(await screen.findByText("turn_start")).toBeInTheDocument();
    });

    it("renders PR link from the rail", async () => {
      renderAt("/projects/alpha/runs/COD-10");
      const pr = detailFixture.pull_requests[0];
      const link = await screen.findByRole("link", { name: `#${pr.github_pr_number}` });
      expect(link).toHaveAttribute(
        "href",
        `https://github.com/${pr.github_owner}/${pr.github_repo}/pull/${pr.github_pr_number}`,
      );
    });

    it("sets document.title to '<identifier> — Harmony'", async () => {
      renderAt("/projects/alpha/runs/COD-10");
      // Wait for the page to load and the effect to fire
      await screen.findByRole("heading", { level: 1 });
      expect(document.title).toBe("COD-10 — Harmony");
    });
  });

  describe("404 state", () => {
    beforeEach(() => {
      vi.stubGlobal(
        "fetch",
        makeFetch(
          jsonResponse(
            { error: { code: "run_not_found", message: "Run not found" } },
            404,
          ),
          jsonResponse(streamFixture),
        ),
      );
    });

    it("renders 'Run not found' heading", async () => {
      renderAt("/projects/alpha/runs/MISSING-99");
      expect(await screen.findByText("Run not found")).toBeInTheDocument();
    });

    it("renders a back link to the project page", async () => {
      renderAt("/projects/alpha/runs/MISSING-99");
      const link = await screen.findByRole("link", { name: /back to project/i });
      expect(link).toHaveAttribute("href", "/projects/alpha");
    });
  });
});
