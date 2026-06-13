import { render, screen, waitFor } from "@testing-library/react";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { describe, it, expect, vi, afterEach } from "vitest";
import { EvidenceTab } from "@/features/project/components/EvidenceTab";
import artifactsFixture from "@/test/fixtures/project_artifacts_page.fixture.json";

afterEach(() => vi.restoreAllMocks());

function renderTab(fetchImpl: () => Promise<Response>) {
  vi.stubGlobal("fetch", vi.fn(fetchImpl));
  const qc = new QueryClient({ defaultOptions: { queries: { retry: false } } });
  return render(
    <QueryClientProvider client={qc}>
      <EvidenceTab slug="alpha" />
    </QueryClientProvider>,
  );
}

function makeOkFetch(body: object) {
  return () =>
    Promise.resolve(
      new Response(JSON.stringify(body), {
        status: 200,
        headers: { "content-type": "application/json" },
      }),
    );
}

describe("EvidenceTab", () => {
  it("renders artifact groups from fixture: screenshot as img, report as download link", async () => {
    renderTab(makeOkFetch(artifactsFixture));

    // Wait for data to load
    await waitFor(() =>
      expect(screen.queryByRole("img")).not.toBeNull(),
    );

    // Screenshot artifact: img linking to artifact URL
    const img = screen.getByRole("img", { name: "screenshot" });
    expect(img).toBeInTheDocument();
    expect(img).toHaveAttribute("src", "/api/v1/artifacts/art-uuid-1");

    // The link wrapping the img
    const imgLink = img.closest("a");
    expect(imgLink).toHaveAttribute("href", "/api/v1/artifacts/art-uuid-1");
    expect(imgLink).toHaveAttribute("target", "_blank");
    expect(imgLink).toHaveAttribute("rel", "noreferrer");

    // Report artifact (unattached): download link
    const downloadLink = screen.getByRole("link", { name: /report/i });
    expect(downloadLink).toHaveAttribute("href", "/api/v1/artifacts/art-uuid-2");
    expect(downloadLink).toHaveAttribute("download");
  });

  it("groups artifacts by work_run_id: COD-42 group has screenshot, Unattached group has report", async () => {
    renderTab(makeOkFetch(artifactsFixture));

    await waitFor(() => expect(screen.queryByRole("img")).not.toBeNull());

    // COD-42 identifier present
    expect(screen.getByText("COD-42")).toBeInTheDocument();

    // Unattached group label
    expect(screen.getByText("Unattached")).toBeInTheDocument();

    // completed badge from run
    expect(screen.getByText("completed")).toBeInTheDocument();
  });

  it("shows empty state when artifacts array is empty", async () => {
    renderTab(makeOkFetch({ artifacts: [] }));

    await waitFor(() =>
      expect(screen.getByText("No evidence yet.")).toBeInTheDocument(),
    );
  });

  it("shows error alert and retry button on API failure", async () => {
    renderTab(() =>
      Promise.resolve(
        new Response(
          JSON.stringify({ error: { code: "not_found", message: "Project not found" } }),
          { status: 404, headers: { "content-type": "application/json" } },
        ),
      ),
    );

    await waitFor(() =>
      expect(screen.getByText("Error loading evidence")).toBeInTheDocument(),
    );
    expect(screen.getByRole("button", { name: /retry/i })).toBeInTheDocument();
  });

  it("renders identifier as em-dash when work_run is null", async () => {
    renderTab(makeOkFetch({ artifacts: [artifactsFixture.artifacts[1]] }));

    await waitFor(() =>
      expect(screen.getByText("—")).toBeInTheDocument(),
    );
  });
});
