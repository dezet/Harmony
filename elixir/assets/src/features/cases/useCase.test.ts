import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { renderHook, waitFor } from "@testing-library/react";
import { createElement, type ReactNode } from "react";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import caseDetailFixture from "@/test/fixtures/case_detail.fixture.json";
import { makeFakeSocket, type FakeSocket } from "@/test/fakeSocket";
import { CASE_KEY } from "@/lib/queryClient";
import { useCase } from "@/features/cases/useCase";

let fakeSocket: FakeSocket;

vi.mock("@/lib/socket", async (importOriginal) => {
  const original = await importOriginal<typeof import("@/lib/socket")>();
  return { ...original, getSocket: () => fakeSocket };
});

const REF = "jira_aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa";

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

describe("useCase", () => {
  it("loads the case detail under [case, ref]", async () => {
    const fetchMock = vi.fn<(input: RequestInfo | URL) => Promise<Response>>(
      async () => new Response(JSON.stringify(caseDetailFixture), { status: 200, headers: { "content-type": "application/json" } }),
    );
    vi.stubGlobal("fetch", fetchMock);
    const qc = new QueryClient({ defaultOptions: { queries: { retry: false } } });

    const { result, unmount } = renderHook(() => useCase(REF), { wrapper: wrapperFor(qc) });

    await waitFor(() => expect(result.current.isSuccess).toBe(true));
    expect(fetchMock.mock.calls[0][0]).toBe(`/api/v1/cases/${REF}`);
    expect(result.current.data?.case.ref).toBe(REF);
    expect(qc.getQueryData(CASE_KEY(REF))).toEqual(caseDetailFixture);
    expect(fakeSocket.channel).toHaveBeenCalledWith("intake:workspace", {});
    unmount();
  });

  it("stays idle without a ref", () => {
    const fetchMock = vi.fn();
    vi.stubGlobal("fetch", fetchMock);
    const qc = new QueryClient();

    const { result, unmount } = renderHook(() => useCase(undefined), { wrapper: wrapperFor(qc) });

    expect(result.current.fetchStatus).toBe("idle");
    expect(fetchMock).not.toHaveBeenCalled();
    unmount();
  });

  it("surfaces an API error instead of throwing", async () => {
    vi.stubGlobal(
      "fetch",
      vi.fn(
        async () =>
          new Response(JSON.stringify({ error: { code: "not_found", message: "Not found" } }), {
            status: 404,
            headers: { "content-type": "application/json" },
          }),
      ),
    );
    const qc = new QueryClient({ defaultOptions: { queries: { retry: false } } });

    const { result, unmount } = renderHook(() => useCase(REF), { wrapper: wrapperFor(qc) });

    await waitFor(() => expect(result.current.isError).toBe(true));
    expect(result.current.error).toMatchObject({ code: "not_found", status: 404 });
    unmount();
  });
});
