import { render, screen, waitFor } from "@testing-library/react";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { describe, it, expect, vi, afterEach } from "vitest";
import { RuntimePage } from "@/features/runtime/RuntimePage";

afterEach(() => vi.restoreAllMocks());

function renderPage(statePayload: object) {
  vi.stubGlobal(
    "fetch",
    vi.fn(
      async () =>
        new Response(JSON.stringify(statePayload), {
          status: 200,
          headers: { "content-type": "application/json" },
        }),
    ),
  );
  const qc = new QueryClient({ defaultOptions: { queries: { retry: false } } });
  return render(
    <QueryClientProvider client={qc}>
      <RuntimePage />
    </QueryClientProvider>,
  );
}

describe("RuntimePage", () => {
  it("renders sandbox info and rate limits when present", async () => {
    renderPage({
      generated_at: "2026-06-12T00:00:00Z",
      runtime: {
        sandbox: {
          posture: "bubblewrap",
          bubblewrap_available: true,
          apparmor_restrict_unprivileged_userns: null,
          thread_sandbox: null,
          turn_sandbox_type: null,
          warnings: [],
        },
      },
      rate_limits: { primary: { used_percent: 42 } },
    });

    await waitFor(() =>
      expect(screen.getByRole("heading", { name: "Runtime" })).toBeInTheDocument(),
    );
    expect(screen.getByText(/bubblewrap/)).toBeInTheDocument();
    expect(screen.getByRole("heading", { name: "Rate limits" })).toBeInTheDocument();
  });

  it("renders empty messages when runtime data is absent", async () => {
    renderPage({ generated_at: "2026-06-12T00:00:00Z" });
    await waitFor(() =>
      expect(screen.getByText(/no sandbox info reported/i)).toBeInTheDocument(),
    );
    expect(screen.getByText(/no rate limit data/i)).toBeInTheDocument();
  });
});
