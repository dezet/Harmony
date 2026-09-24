import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { act, renderHook, waitFor } from "@testing-library/react";
import { createElement, type ReactNode } from "react";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import casesPageFixture from "@/test/fixtures/cases_page.fixture.json";
import { makeFakeSocket, type FakeSocket } from "@/test/fakeSocket";
import { CASES_KEY } from "@/lib/queryClient";
import { useCases } from "@/features/cases/useCases";
import type { CaseFilters, CasesPage } from "@/types/contract";

let fakeSocket: FakeSocket;

vi.mock("@/lib/socket", async (importOriginal) => {
  const original = await importOriginal<typeof import("@/lib/socket")>();
  return { ...original, getSocket: () => fakeSocket };
});

const fixture = casesPageFixture as CasesPage;

function page(title: string, nextCursor: string | null = null): CasesPage {
  return {
    ...fixture,
    items: [{ ...fixture.items[0], title }],
    meta: { ...fixture.meta, next_cursor: nextCursor },
  };
}

function json(body: unknown): Response {
  return new Response(JSON.stringify(body), { status: 200, headers: { "content-type": "application/json" } });
}

interface PendingRequest {
  url: string;
  signal: AbortSignal | undefined;
  resolve: (body: unknown) => void;
}

// fetch stub whose responses the test releases in any order.
function deferredFetch() {
  const requests: PendingRequest[] = [];
  const fetchMock = vi.fn(
    (input: RequestInfo | URL, init?: RequestInit) =>
      new Promise<Response>((resolve) => {
        requests.push({ url: String(input), signal: init?.signal ?? undefined, resolve: (body) => resolve(json(body)) });
      }),
  );
  vi.stubGlobal("fetch", fetchMock);
  return requests;
}

function wrapperFor(qc: QueryClient) {
  return ({ children }: { children: ReactNode }) => createElement(QueryClientProvider, { client: qc }, children);
}

function newClient() {
  return new QueryClient({ defaultOptions: { queries: { retry: false } } });
}

beforeEach(() => {
  fakeSocket = makeFakeSocket();
});

afterEach(() => {
  vi.unstubAllGlobals();
  vi.restoreAllMocks();
});

describe("useCases", () => {
  it("loads the first page under [cases, filters] and subscribes to intake:workspace", async () => {
    const requests = deferredFetch();
    const qc = newClient();
    const filters: CaseFilters = { project: "alpha", filter: "decision", q: "OPS-1" };
    const { result, unmount } = renderHook(() => useCases(filters), { wrapper: wrapperFor(qc) });

    await waitFor(() => expect(requests).toHaveLength(1));
    expect(requests[0].url).toBe("/api/v1/cases?project=alpha&filter=decision&q=OPS-1");
    expect(fakeSocket.channel).toHaveBeenCalledWith("intake:workspace", {});

    act(() => requests[0].resolve(page("Alpha case")));
    await waitFor(() => expect(result.current.isSuccess).toBe(true));
    expect(result.current.data?.pages[0].items[0].title).toBe("Alpha case");
    expect(qc.getQueryData(CASES_KEY(filters))).toBeDefined();
    unmount();
  });

  it("loads the next page with the cursor of the previous one", async () => {
    const requests = deferredFetch();
    const qc = newClient();
    const { result, unmount } = renderHook(() => useCases({}), { wrapper: wrapperFor(qc) });

    await waitFor(() => expect(requests).toHaveLength(1));
    act(() => requests[0].resolve(page("First", "cursor-2")));
    await waitFor(() => expect(result.current.hasNextPage).toBe(true));

    act(() => {
      void result.current.fetchNextPage();
    });
    await waitFor(() => expect(requests).toHaveLength(2));
    expect(requests[1].url).toBe("/api/v1/cases?cursor=cursor-2");

    act(() => requests[1].resolve(page("Second")));
    await waitFor(() => expect(result.current.data?.pages).toHaveLength(2));
    expect(result.current.hasNextPage).toBe(false);
    unmount();
  });

  it("never shows the previous project's data, even when its response arrives last", async () => {
    const requests = deferredFetch();
    const qc = newClient();
    const { result, rerender, unmount } = renderHook(({ filters }: { filters: CaseFilters }) => useCases(filters), {
      wrapper: wrapperFor(qc),
      initialProps: { filters: { project: "alpha" } },
    });

    await waitFor(() => expect(requests).toHaveLength(1));
    rerender({ filters: { project: "beta" } });
    await waitFor(() => expect(requests).toHaveLength(2));
    expect(requests[1].url).toBe("/api/v1/cases?project=beta");

    // While beta is loading nothing from alpha is shown.
    expect(result.current.data).toBeUndefined();
    expect(result.current.isPending).toBe(true);
    expect(requests[0].signal?.aborted).toBe(true);

    act(() => requests[1].resolve(page("Beta case")));
    await waitFor(() => expect(result.current.isSuccess).toBe(true));

    act(() => requests[0].resolve(page("Alpha case")));
    await act(async () => {
      await Promise.resolve();
    });
    expect(result.current.data?.pages[0].items[0].title).toBe("Beta case");
    expect(qc.getQueryData(CASES_KEY({ project: "alpha" }))).toBeUndefined();
    unmount();
  });
});
