import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { act, renderHook, waitFor } from "@testing-library/react";
import { createElement, type ReactNode } from "react";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { makeFakeSocket, type FakeSocket } from "@/test/fakeSocket";
import { CASE_EVENTS_KEY } from "@/lib/queryClient";
import { useCaseEvents } from "@/features/cases/useCaseEvents";
import type { CaseEventsPage } from "@/types/contract";

let fakeSocket: FakeSocket;

vi.mock("@/lib/socket", async (importOriginal) => {
  const original = await importOriginal<typeof import("@/lib/socket")>();
  return { ...original, getSocket: () => fakeSocket };
});

const REF = "jira_aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa";

function eventsPage(id: string, nextCursor: string | null): CaseEventsPage {
  return {
    items: [
      {
        id,
        type: "case_detected",
        actor: "system",
        occurred_at: "2026-09-22T10:00:00Z",
        operation: null,
        recipient: null,
        payload: {},
      },
    ],
    meta: { next_cursor: nextCursor, page_size: 50 },
  };
}

function wrapperFor(qc: QueryClient) {
  return ({ children }: { children: ReactNode }) => createElement(QueryClientProvider, { client: qc }, children);
}

beforeEach(() => {
  fakeSocket = makeFakeSocket();
});

afterEach(() => {
  vi.unstubAllGlobals();
  vi.restoreAllMocks();
});

describe("useCaseEvents", () => {
  it("pages the case history under [case-events, ref]", async () => {
    const fetchMock = vi.fn(async (input: RequestInfo | URL) => {
      const body = String(input).includes("cursor=") ? eventsPage("e2", null) : eventsPage("e1", "cursor-2");
      return new Response(JSON.stringify(body), { status: 200, headers: { "content-type": "application/json" } });
    });
    vi.stubGlobal("fetch", fetchMock);
    const qc = new QueryClient({ defaultOptions: { queries: { retry: false } } });

    const { result, unmount } = renderHook(() => useCaseEvents(REF), { wrapper: wrapperFor(qc) });

    await waitFor(() => expect(result.current.hasNextPage).toBe(true));
    expect(fetchMock.mock.calls[0][0]).toBe(`/api/v1/cases/${REF}/events`);

    act(() => {
      void result.current.fetchNextPage();
    });
    await waitFor(() => expect(result.current.data?.pages).toHaveLength(2));
    expect(fetchMock.mock.calls[1][0]).toBe(`/api/v1/cases/${REF}/events?cursor=cursor-2`);
    expect(result.current.data?.pages.flatMap((p) => p.items.map((item) => item.id))).toEqual(["e1", "e2"]);
    expect(qc.getQueryData(CASE_EVENTS_KEY(REF))).toBeDefined();
    expect(fakeSocket.channel).toHaveBeenCalledWith("intake:workspace", {});
    unmount();
  });

  it("stays idle without a ref", () => {
    const fetchMock = vi.fn();
    vi.stubGlobal("fetch", fetchMock);
    const qc = new QueryClient();

    const { result, unmount } = renderHook(() => useCaseEvents(undefined), { wrapper: wrapperFor(qc) });

    expect(result.current.fetchStatus).toBe("idle");
    expect(fetchMock).not.toHaveBeenCalled();
    unmount();
  });
});
