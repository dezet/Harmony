import { describe, it, expect, vi, beforeEach } from "vitest";
import { renderHook } from "@testing-library/react";
import { QueryClient } from "@tanstack/react-query";
import type { RunDetail, RunStreamItem, Tokens } from "@/types/contract";
import { RUN_KEY, RUN_STREAM_KEY } from "@/lib/queryClient";
import { useRunChannel } from "@/features/run/useRunChannel";

// ─── Mock phoenix ────────────────────────────────────────────────────────────

type ChannelEventHandler = (payload: unknown) => void;

/**
 * A minimal chainable Push mock. Stores callbacks registered via `.receive()`
 * so tests can trigger them with `_triggerReceive(event)`.
 */
interface FakePush {
  receive: (event: string, cb: () => void) => FakePush;
  _triggerReceive: (event: string) => void;
}

function makeFakePush(): FakePush {
  const receiveHandlers: Record<string, () => void> = {};
  const push: FakePush = {
    receive(event: string, cb: () => void) {
      receiveHandlers[event] = cb;
      return push; // chainable
    },
    _triggerReceive(event: string) {
      receiveHandlers[event]?.();
    },
  };
  return push;
}

interface FakeChannel {
  on: (event: string, cb: ChannelEventHandler) => number;
  join: () => FakePush;
  leave: ReturnType<typeof vi.fn>;
  _emit: (event: string, payload: unknown) => void;
  _topic: string;
  _joinPush: FakePush;
}

interface FakeSocket {
  channel: ReturnType<typeof vi.fn>;
  connect: ReturnType<typeof vi.fn>;
  disconnect: ReturnType<typeof vi.fn>;
  _channels: FakeChannel[];
}

let fakeSocket: FakeSocket;

function makeFakeChannel(topic: string): FakeChannel {
  const handlers: Record<string, ChannelEventHandler> = {};
  const joinPush = makeFakePush();
  return {
    _topic: topic,
    _joinPush: joinPush,
    on: (event: string, cb: ChannelEventHandler) => {
      handlers[event] = cb;
      return 0;
    },
    join: () => joinPush,
    leave: vi.fn(() => ({ receive: () => undefined })),
    _emit: (event: string, payload: unknown) => {
      handlers[event]?.(payload);
    },
  };
}

vi.mock("phoenix", () => {
  return {
    Socket: vi.fn().mockImplementation(() => fakeSocket),
    Channel: vi.fn(),
  };
});

// Also mock getSocket so it returns our fakeSocket's channel factory
vi.mock("@/lib/socket", async (importOriginal) => {
  const original = await importOriginal<typeof import("@/lib/socket")>();
  return {
    ...original,
    getSocket: () => fakeSocket,
  };
});

// ─── Fixtures ────────────────────────────────────────────────────────────────

const IDENTIFIER = "ENG-42";

const SAMPLE_RUN_DETAIL: RunDetail = {
  identifier: IDENTIFIER,
  issue_id: "issue-abc",
  work_run_id: "wr-1",
  status: "running",
  project: { id: "p1", slug: "my-project", name: "My Project" },
  workspace: { path: "/work", host: "host-1" },
  session_id: "sess-1",
  turn_count: 3,
  started_at: "2026-01-01T00:00:00Z",
  last_event_at: "2026-01-01T00:01:00Z",
  last_event: "tool_use",
  last_message: "hello",
  tokens: { input_tokens: 100, output_tokens: 50, total_tokens: 150 },
  attempts: { restart_count: 0, current_retry_attempt: null },
  pull_requests: [],
  artifacts: [],
  last_error: null,
  stream_cursor: null,
};

const SAMPLE_STREAM_ITEM: RunStreamItem = {
  id: "item-1",
  kind: "live_event",
  type: "tool_use",
  at: "2026-01-01T00:02:00Z",
  payload: { message: "doing work" },
};

// ─── Test setup ─────────────────────────────────────────────────────────────

beforeEach(() => {
  fakeSocket = {
    connect: vi.fn(),
    disconnect: vi.fn(),
    _channels: [],
    channel: vi.fn().mockImplementation((topic: string) => {
      const ch = makeFakeChannel(topic);
      fakeSocket._channels.push(ch);
      return ch;
    }),
  };
});

// ─── Tests ───────────────────────────────────────────────────────────────────

describe("useRunChannel", () => {
  it("does not create a channel when issueId is null", () => {
    const qc = new QueryClient();
    renderHook(() => useRunChannel(qc, null, IDENTIFIER));
    expect(fakeSocket.channel).not.toHaveBeenCalled();
  });

  it("joins the correct topic when issueId is provided", () => {
    const qc = new QueryClient();
    renderHook(() => useRunChannel(qc, "issue-abc", IDENTIFIER));
    expect(fakeSocket.channel).toHaveBeenCalledWith(
      "observability:run:issue-abc",
      {},
    );
    expect(fakeSocket._channels).toHaveLength(1);
  });

  it("calls channel.leave() on unmount", () => {
    const qc = new QueryClient();
    const { unmount } = renderHook(() =>
      useRunChannel(qc, "issue-abc", IDENTIFIER),
    );
    const ch = fakeSocket._channels[0];
    unmount();
    expect(ch.leave).toHaveBeenCalled();
  });

  it("calls channel.leave() and rejoins when issueId changes", () => {
    const qc = new QueryClient();
    const { rerender, unmount } = renderHook(
      ({ issueId }: { issueId: string | null }) =>
        useRunChannel(qc, issueId, IDENTIFIER),
      { initialProps: { issueId: "issue-abc" } },
    );

    const firstChannel = fakeSocket._channels[0];
    rerender({ issueId: "issue-xyz" });

    expect(firstChannel.leave).toHaveBeenCalled();
    expect(fakeSocket.channel).toHaveBeenLastCalledWith(
      "observability:run:issue-xyz",
      {},
    );

    unmount();
  });

  describe("status_changed", () => {
    it("patches status, last_error, and last_event_at on RUN_KEY", () => {
      const qc = new QueryClient();
      qc.setQueryData(RUN_KEY(IDENTIFIER), SAMPLE_RUN_DETAIL);

      renderHook(() => useRunChannel(qc, "issue-abc", IDENTIFIER));
      const ch = fakeSocket._channels[0];

      ch._emit("status_changed", {
        issue_id: "issue-abc",
        identifier: IDENTIFIER,
        status: "blocked",
        last_error: "timed out",
        at: "2026-01-01T00:05:00Z",
      });

      const updated = qc.getQueryData<RunDetail>(RUN_KEY(IDENTIFIER));
      expect(updated?.status).toBe("blocked");
      expect(updated?.last_error).toBe("timed out");
      expect(updated?.last_event_at).toBe("2026-01-01T00:05:00Z");
      // Untouched fields remain
      expect(updated?.turn_count).toBe(3);
      expect(updated?.tokens).toEqual(SAMPLE_RUN_DETAIL.tokens);
    });

    it("is a no-op when RUN_KEY cache is empty", () => {
      const qc = new QueryClient();
      renderHook(() => useRunChannel(qc, "issue-abc", IDENTIFIER));
      const ch = fakeSocket._channels[0];

      expect(() => {
        ch._emit("status_changed", {
          issue_id: "issue-abc",
          identifier: IDENTIFIER,
          status: "blocked",
          last_error: null,
          at: "2026-01-01T00:05:00Z",
        });
      }).not.toThrow();

      expect(qc.getQueryData(RUN_KEY(IDENTIFIER))).toBeUndefined();
    });
  });

  describe("tokens_updated", () => {
    it("patches tokens, turn_count, and last_event_at on RUN_KEY", () => {
      const qc = new QueryClient();
      qc.setQueryData(RUN_KEY(IDENTIFIER), SAMPLE_RUN_DETAIL);

      renderHook(() => useRunChannel(qc, "issue-abc", IDENTIFIER));
      const ch = fakeSocket._channels[0];

      const newTokens: Tokens = {
        input_tokens: 200,
        output_tokens: 100,
        total_tokens: 300,
      };

      ch._emit("tokens_updated", {
        issue_id: "issue-abc",
        identifier: IDENTIFIER,
        tokens: newTokens,
        turn_count: 7,
        at: "2026-01-01T00:06:00Z",
      });

      const updated = qc.getQueryData<RunDetail>(RUN_KEY(IDENTIFIER));
      expect(updated?.tokens).toEqual(newTokens);
      expect(updated?.turn_count).toBe(7);
      expect(updated?.last_event_at).toBe("2026-01-01T00:06:00Z");
      // Untouched fields remain
      expect(updated?.status).toBe("running");
      expect(updated?.last_error).toBeNull();
    });

    it("is a no-op when RUN_KEY cache is empty", () => {
      const qc = new QueryClient();
      renderHook(() => useRunChannel(qc, "issue-abc", IDENTIFIER));
      const ch = fakeSocket._channels[0];

      expect(() => {
        ch._emit("tokens_updated", {
          issue_id: "issue-abc",
          identifier: IDENTIFIER,
          tokens: { input_tokens: 1, output_tokens: 1, total_tokens: 2 },
          turn_count: 1,
          at: "2026-01-01T00:06:00Z",
        });
      }).not.toThrow();

      expect(qc.getQueryData(RUN_KEY(IDENTIFIER))).toBeUndefined();
    });
  });

  describe("event_appended", () => {
    it("appends item to the last page of an existing stream cache", () => {
      const qc = new QueryClient();
      const existingItem: RunStreamItem = {
        id: "existing-1",
        kind: "work_event",
        type: "started",
        at: "2026-01-01T00:00:00Z",
        payload: null,
      };

      qc.setQueryData(RUN_STREAM_KEY(IDENTIFIER), {
        pages: [{ items: [existingItem], meta: { next_cursor: null, has_live: true } }],
        pageParams: [undefined],
      });

      renderHook(() => useRunChannel(qc, "issue-abc", IDENTIFIER));
      const ch = fakeSocket._channels[0];

      ch._emit("event_appended", {
        issue_id: "issue-abc",
        identifier: IDENTIFIER,
        item: SAMPLE_STREAM_ITEM,
      });

      const updated = qc.getQueryData<{ pages: { items: RunStreamItem[] }[] }>(
        RUN_STREAM_KEY(IDENTIFIER),
      );
      const lastPage = updated?.pages[updated.pages.length - 1];
      expect(lastPage?.items).toHaveLength(2);
      expect(lastPage?.items[1]).toEqual(SAMPLE_STREAM_ITEM);
    });

    it("appends to the last page when multiple pages exist", () => {
      const qc = new QueryClient();
      const page1Item: RunStreamItem = {
        id: "p1-item",
        kind: "work_event",
        type: "started",
        at: "2026-01-01T00:00:00Z",
        payload: null,
      };
      const page2Item: RunStreamItem = {
        id: "p2-item",
        kind: "work_event",
        type: "tool_use",
        at: "2026-01-01T00:01:00Z",
        payload: null,
      };

      qc.setQueryData(RUN_STREAM_KEY(IDENTIFIER), {
        pages: [
          { items: [page1Item], meta: { next_cursor: "cursor-1", has_live: false } },
          { items: [page2Item], meta: { next_cursor: null, has_live: true } },
        ],
        pageParams: [undefined, "cursor-1"],
      });

      renderHook(() => useRunChannel(qc, "issue-abc", IDENTIFIER));
      const ch = fakeSocket._channels[0];

      ch._emit("event_appended", {
        issue_id: "issue-abc",
        identifier: IDENTIFIER,
        item: SAMPLE_STREAM_ITEM,
      });

      const updated = qc.getQueryData<{
        pages: { items: RunStreamItem[] }[];
        pageParams: unknown[];
      }>(RUN_STREAM_KEY(IDENTIFIER));
      expect(updated?.pages).toHaveLength(2);
      // First page is unchanged
      expect(updated?.pages[0].items).toHaveLength(1);
      expect(updated?.pages[0].items[0].id).toBe("p1-item");
      // Item appended to last page
      expect(updated?.pages[1].items).toHaveLength(2);
      expect(updated?.pages[1].items[1]).toEqual(SAMPLE_STREAM_ITEM);
    });

    it("creates a synthetic page when stream cache is empty", () => {
      const qc = new QueryClient();
      renderHook(() => useRunChannel(qc, "issue-abc", IDENTIFIER));
      const ch = fakeSocket._channels[0];

      ch._emit("event_appended", {
        issue_id: "issue-abc",
        identifier: IDENTIFIER,
        item: SAMPLE_STREAM_ITEM,
      });

      const data = qc.getQueryData<{
        pages: { items: RunStreamItem[]; meta: { next_cursor: null; has_live: boolean } }[];
        pageParams: unknown[];
      }>(RUN_STREAM_KEY(IDENTIFIER));

      expect(data?.pages).toHaveLength(1);
      expect(data?.pages[0].items).toHaveLength(1);
      expect(data?.pages[0].items[0]).toEqual(SAMPLE_STREAM_ITEM);
      expect(data?.pages[0].meta.next_cursor).toBeNull();
      expect(data?.pages[0].meta.has_live).toBe(true);
      expect(data?.pageParams).toEqual([undefined]);
    });

    it("does not append a duplicate item (same id)", () => {
      const qc = new QueryClient();

      qc.setQueryData(RUN_STREAM_KEY(IDENTIFIER), {
        pages: [
          {
            items: [SAMPLE_STREAM_ITEM],
            meta: { next_cursor: null, has_live: true },
          },
        ],
        pageParams: [undefined],
      });

      renderHook(() => useRunChannel(qc, "issue-abc", IDENTIFIER));
      const ch = fakeSocket._channels[0];

      // Emit the same item again (simulating re-join)
      ch._emit("event_appended", {
        issue_id: "issue-abc",
        identifier: IDENTIFIER,
        item: SAMPLE_STREAM_ITEM,
      });

      const updated = qc.getQueryData<{ pages: { items: RunStreamItem[] }[] }>(
        RUN_STREAM_KEY(IDENTIFIER),
      );
      expect(updated?.pages[0].items).toHaveLength(1);
    });

    it("deduplicates against items in earlier pages as well", () => {
      const qc = new QueryClient();
      // Put the item in page 1, and try to append it again via channel
      qc.setQueryData(RUN_STREAM_KEY(IDENTIFIER), {
        pages: [
          {
            items: [SAMPLE_STREAM_ITEM],
            meta: { next_cursor: "cursor-1", has_live: false },
          },
          {
            items: [],
            meta: { next_cursor: null, has_live: true },
          },
        ],
        pageParams: [undefined, "cursor-1"],
      });

      renderHook(() => useRunChannel(qc, "issue-abc", IDENTIFIER));
      const ch = fakeSocket._channels[0];

      ch._emit("event_appended", {
        issue_id: "issue-abc",
        identifier: IDENTIFIER,
        item: SAMPLE_STREAM_ITEM,
      });

      const updated = qc.getQueryData<{ pages: { items: RunStreamItem[] }[] }>(
        RUN_STREAM_KEY(IDENTIFIER),
      );
      // Page 1 still has 1 item, page 2 still has 0 (not appended)
      expect(updated?.pages[0].items).toHaveLength(1);
      expect(updated?.pages[1].items).toHaveLength(0);
    });
  });

  describe("onConnectionError", () => {
    it("calls onConnectionError when the join receives 'error'", () => {
      const qc = new QueryClient();
      const onConnectionError = vi.fn();
      renderHook(() => useRunChannel(qc, "issue-abc", IDENTIFIER, onConnectionError));

      const ch = fakeSocket._channels[0];
      ch._joinPush._triggerReceive("error");

      expect(onConnectionError).toHaveBeenCalledTimes(1);
    });

    it("calls onConnectionError when the join receives 'timeout'", () => {
      const qc = new QueryClient();
      const onConnectionError = vi.fn();
      renderHook(() => useRunChannel(qc, "issue-abc", IDENTIFIER, onConnectionError));

      const ch = fakeSocket._channels[0];
      ch._joinPush._triggerReceive("timeout");

      expect(onConnectionError).toHaveBeenCalledTimes(1);
    });

    it("does not call onConnectionError when issueId is null (no join)", () => {
      const qc = new QueryClient();
      const onConnectionError = vi.fn();
      renderHook(() => useRunChannel(qc, null, IDENTIFIER, onConnectionError));

      expect(fakeSocket.channel).not.toHaveBeenCalled();
      expect(onConnectionError).not.toHaveBeenCalled();
    });

    it("does not throw when no onConnectionError is provided and join errors", () => {
      const qc = new QueryClient();
      renderHook(() => useRunChannel(qc, "issue-abc", IDENTIFIER));

      const ch = fakeSocket._channels[0];
      expect(() => ch._joinPush._triggerReceive("error")).not.toThrow();
    });
  });
});
