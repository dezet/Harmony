import { render, screen, waitFor } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { describe, it, expect, vi, afterEach } from "vitest";
import { ActivityTab } from "@/features/project/components/ActivityTab";
import activityFixture from "@/test/fixtures/project_activity_page.fixture.json";

afterEach(() => vi.restoreAllMocks());

function renderTab(fetchImpl: () => Promise<Response>) {
  vi.stubGlobal("fetch", vi.fn(fetchImpl));
  const qc = new QueryClient({ defaultOptions: { queries: { retry: false } } });
  return render(
    <QueryClientProvider client={qc}>
      <ActivityTab slug="alpha" />
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

describe("ActivityTab", () => {
  it("renders items from fixture via StreamItemRow", async () => {
    renderTab(makeOkFetch({ ...activityFixture, meta: { next_cursor: null } }));

    await waitFor(() =>
      expect(screen.getByText("turn_start")).toBeInTheDocument(),
    );

    expect(screen.getByText("turn_end")).toBeInTheDocument();
    // Payload summary from fixture
    expect(screen.getByText(/Turn completed successfully/i)).toBeInTheDocument();
  });

  it("shows empty state when items array is empty", async () => {
    renderTab(makeOkFetch({ items: [], meta: { next_cursor: null } }));

    await waitFor(() =>
      expect(screen.getByText("No activity yet.")).toBeInTheDocument(),
    );
  });

  it("shows Load more button when hasNextPage is true", async () => {
    renderTab(makeOkFetch(activityFixture));

    await waitFor(() =>
      expect(screen.getByText("turn_start")).toBeInTheDocument(),
    );

    expect(screen.getByRole("button", { name: /load more/i })).toBeInTheDocument();
  });

  it("does not show Load more button when next_cursor is null", async () => {
    renderTab(makeOkFetch({ ...activityFixture, meta: { next_cursor: null } }));

    await waitFor(() =>
      expect(screen.getByText("turn_start")).toBeInTheDocument(),
    );

    expect(screen.queryByRole("button", { name: /load more/i })).not.toBeInTheDocument();
  });

  it("shows error alert on API failure", async () => {
    renderTab(() =>
      Promise.resolve(
        new Response(
          JSON.stringify({ error: { code: "not_found", message: "Project not found" } }),
          { status: 404, headers: { "content-type": "application/json" } },
        ),
      ),
    );

    await waitFor(() =>
      expect(screen.getByText("Error loading activity")).toBeInTheDocument(),
    );
    expect(screen.getByRole("button", { name: /retry/i })).toBeInTheDocument();
  });

  it("calls fetchNextPage when Load more is clicked", async () => {
    const user = userEvent.setup();
    // First call returns page 1 with a cursor; second call returns page 2 with no cursor
    let callCount = 0;
    renderTab(() => {
      callCount++;
      if (callCount <= 1) {
        return Promise.resolve(
          new Response(JSON.stringify(activityFixture), {
            status: 200,
            headers: { "content-type": "application/json" },
          }),
        );
      }
      return Promise.resolve(
        new Response(
          JSON.stringify({ items: [], meta: { next_cursor: null } }),
          { status: 200, headers: { "content-type": "application/json" } },
        ),
      );
    });

    await waitFor(() =>
      expect(screen.getByRole("button", { name: /load more/i })).toBeInTheDocument(),
    );

    await user.click(screen.getByRole("button", { name: /load more/i }));

    // After clicking, fetchNextPage is called; button eventually disappears (no more pages)
    await waitFor(() =>
      expect(screen.queryByRole("button", { name: /load more/i })).not.toBeInTheDocument(),
    );
  });
});
