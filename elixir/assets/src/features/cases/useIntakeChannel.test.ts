import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { act, renderHook } from "@testing-library/react";
import { createElement, type ReactNode } from "react";
import { QueryClient, QueryClientProvider, QueryObserver, type QueryKey } from "@tanstack/react-query";
import { makeFakeSocket, type FakeSocket } from "@/test/fakeSocket";
import {
  AUTOMATION_KEY,
  AUTOMATIONS_KEY,
  CASE_EVENTS_KEY,
  CASE_KEY,
  CASES_KEY,
  DASHBOARD_KEY,
  INTEGRATIONS_KEY,
  RUN_KEY,
  WORK_RUNS_KEY,
} from "@/lib/queryClient";
import { invalidationKeys, useIntakeChannel } from "@/features/cases/useIntakeChannel";
import type { IntakeChangedPayload } from "@/types/contract";

let fakeSocket: FakeSocket;

vi.mock("@/lib/socket", async (importOriginal) => {
  const original = await importOriginal<typeof import("@/lib/socket")>();
  return { ...original, getSocket: () => fakeSocket };
});

const CASE_REF = "jira_aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa";
const OTHER_REF = "jira_bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb";
const PROJECT_ID = "11111111-1111-4111-8111-111111111111";
const RULE_ID = "22222222-2222-4222-8222-222222222222";

function changed(overrides: Partial<IntakeChangedPayload> = {}): IntakeChangedPayload {
  return {
    project_id: PROJECT_ID,
    case_ref: CASE_REF,
    rule_id: null,
    revision: 1,
    changed_at: "2026-09-24T10:00:00.000Z",
    ...overrides,
  };
}

function wrapperFor(qc: QueryClient) {
  return ({ children }: { children: ReactNode }) => createElement(QueryClientProvider, { client: qc }, children);
}

function mount(qc: QueryClient) {
  return renderHook(() => useIntakeChannel(), { wrapper: wrapperFor(qc) });
}

function channel() {
  expect(fakeSocket.channels).toHaveLength(1);
  return fakeSocket.channels[0];
}

function seed(qc: QueryClient, key: QueryKey) {
  qc.setQueryData(key, { seeded: true });
}

function invalidated(qc: QueryClient, key: QueryKey): boolean {
  return qc.getQueryState(key)?.isInvalidated ?? false;
}

// An active observer whose fetches are counted, like a mounted screen.
function observe(qc: QueryClient, key: QueryKey) {
  const queryFn = vi.fn(async () => ({ at: Date.now() }));
  const observer = new QueryObserver(qc, { queryKey: key, queryFn, staleTime: Infinity });
  const unsubscribe = observer.subscribe(() => undefined);
  return { queryFn, unsubscribe };
}

function setVisibility(state: DocumentVisibilityState) {
  Object.defineProperty(document, "visibilityState", { configurable: true, get: () => state });
  document.dispatchEvent(new Event("visibilitychange"));
}

beforeEach(() => {
  vi.useFakeTimers();
  fakeSocket = makeFakeSocket();
  setVisibility("visible");
});

afterEach(() => {
  vi.useRealTimers();
});

describe("invalidationKeys", () => {
  it("maps a case change to the case list, the case and its history", () => {
    expect(invalidationKeys(changed())).toEqual([["cases"], ["case", CASE_REF], ["case-events", CASE_REF]]);
  });

  it("maps a rule change to the case list, the rule list and the rule", () => {
    expect(invalidationKeys(changed({ case_ref: null, rule_id: RULE_ID }))).toEqual([
      ["cases"],
      ["automations"],
      ["automation", RULE_ID],
    ]);
  });

  it("maps a workspace change to the case, rule and integration lists", () => {
    expect(invalidationKeys(changed({ project_id: null, case_ref: null }))).toEqual([
      ["cases"],
      ["automations"],
      ["integrations"],
    ]);
  });
});

describe("useIntakeChannel", () => {
  it("joins intake:workspace once on the shared socket and leaves after the last consumer", () => {
    const qc = new QueryClient();
    const first = mount(qc);
    const second = mount(qc);

    expect(fakeSocket.channel).toHaveBeenCalledTimes(1);
    expect(fakeSocket.channel).toHaveBeenCalledWith("intake:workspace", {});
    const ch = channel();

    first.unmount();
    expect(ch.leave).not.toHaveBeenCalled();
    second.unmount();
    expect(ch.leave).toHaveBeenCalledTimes(1);
  });

  it("reports the channel state", () => {
    const qc = new QueryClient();
    const { result, unmount } = mount(qc);
    expect(result.current).toBe("connecting");

    act(() => channel().reply("ok"));
    expect(result.current).toBe("live");

    act(() => channel().error());
    expect(result.current).toBe("reconnecting");

    act(() => channel().reply("error"));
    expect(result.current).toBe("offline");
    unmount();
  });

  it("debounces a burst of events into one invalidation after 250 ms", () => {
    const qc = new QueryClient();
    const spy = vi.spyOn(qc, "invalidateQueries");
    const { unmount } = mount(qc);
    act(() => channel().reply("ok"));

    act(() => {
      channel().emit("changed", changed({ revision: 1 }));
      vi.advanceTimersByTime(100);
      channel().emit("changed", changed({ revision: 2 }));
      vi.advanceTimersByTime(100);
      channel().emit("changed", changed({ revision: 3 }));
      vi.advanceTimersByTime(249);
    });
    expect(spy).not.toHaveBeenCalled();

    act(() => vi.advanceTimersByTime(1));
    expect(spy.mock.calls.map(([filters]) => filters?.queryKey)).toEqual([
      ["cases"],
      ["case", CASE_REF],
      ["case-events", CASE_REF],
    ]);
    unmount();
  });

  it("does not starve under a continuous stream of events", () => {
    const qc = new QueryClient();
    const spy = vi.spyOn(qc, "invalidateQueries");
    const { unmount } = mount(qc);
    act(() => channel().reply("ok"));

    act(() => {
      for (let i = 0; i < 6; i += 1) {
        channel().emit("changed", changed({ revision: i }));
        vi.advanceTimersByTime(200);
      }
    });

    expect(spy).toHaveBeenCalled();
    unmount();
  });

  it("invalidates only the keys of the change and never the observability cache", () => {
    const qc = new QueryClient();
    const keys = {
      list: CASES_KEY({ project: "alpha" }),
      otherList: CASES_KEY({ filter: "decision" }),
      detail: CASE_KEY(CASE_REF),
      events: CASE_EVENTS_KEY(CASE_REF),
      otherDetail: CASE_KEY(OTHER_REF),
      automations: AUTOMATIONS_KEY({}),
      automation: AUTOMATION_KEY(RULE_ID),
      integrations: INTEGRATIONS_KEY,
      dashboard: DASHBOARD_KEY,
      run: RUN_KEY("OPS-1"),
      workRuns: WORK_RUNS_KEY("alpha", {}),
    };
    Object.values(keys).forEach((key) => seed(qc, key));
    const { unmount } = mount(qc);
    act(() => channel().reply("ok"));

    act(() => {
      channel().emit("changed", changed());
      vi.advanceTimersByTime(250);
    });

    expect(invalidated(qc, keys.list)).toBe(true);
    expect(invalidated(qc, keys.otherList)).toBe(true);
    expect(invalidated(qc, keys.detail)).toBe(true);
    expect(invalidated(qc, keys.events)).toBe(true);
    expect(invalidated(qc, keys.otherDetail)).toBe(false);
    expect(invalidated(qc, keys.automations)).toBe(false);
    expect(invalidated(qc, keys.automation)).toBe(false);
    expect(invalidated(qc, keys.integrations)).toBe(false);
    expect(invalidated(qc, keys.dashboard)).toBe(false);
    expect(invalidated(qc, keys.run)).toBe(false);
    expect(invalidated(qc, keys.workRuns)).toBe(false);
    unmount();
  });

  it("ignores malformed events", () => {
    const qc = new QueryClient();
    const spy = vi.spyOn(qc, "invalidateQueries");
    const { unmount } = mount(qc);
    act(() => channel().reply("ok"));

    act(() => {
      channel().emit("changed", null);
      channel().emit("changed", { case_ref: 42, revision: "x" });
      vi.advanceTimersByTime(1_000);
    });

    expect(spy).not.toHaveBeenCalled();
    unmount();
  });

  it("refetches the active intake queries when the channel rejoins after a reconnect", async () => {
    const qc = new QueryClient();
    const list = observe(qc, CASES_KEY({}));
    const dashboard = observe(qc, DASHBOARD_KEY);
    await act(async () => {
      await vi.runOnlyPendingTimersAsync();
    });
    seed(qc, CASE_KEY(OTHER_REF)); // cached but not on screen
    expect(list.queryFn).toHaveBeenCalledTimes(1);
    expect(dashboard.queryFn).toHaveBeenCalledTimes(1);

    const { unmount } = mount(qc);
    act(() => channel().reply("ok"));
    expect(list.queryFn).toHaveBeenCalledTimes(1);

    act(() => channel().error());
    await act(async () => {
      channel().reply("ok");
      await Promise.resolve();
    });

    expect(list.queryFn).toHaveBeenCalledTimes(2);
    expect(dashboard.queryFn).toHaveBeenCalledTimes(1);
    expect(qc.getQueryState(CASE_KEY(OTHER_REF))?.fetchStatus).toBe("idle");
    unmount();
    list.unsubscribe();
    dashboard.unsubscribe();
  });

  it("falls back to a 30 s refetch only while the channel is down and the screen is visible", async () => {
    const qc = new QueryClient();
    const list = observe(qc, CASES_KEY({}));
    await act(async () => {
      await vi.runOnlyPendingTimersAsync();
    });
    const { unmount } = mount(qc);

    act(() => channel().reply("ok"));
    await act(async () => {
      await vi.advanceTimersByTimeAsync(90_000);
    });
    expect(list.queryFn).toHaveBeenCalledTimes(1); // no parallel polling next to a working channel

    act(() => channel().error());
    await act(async () => {
      await vi.advanceTimersByTimeAsync(29_999);
    });
    expect(list.queryFn).toHaveBeenCalledTimes(1);
    await act(async () => {
      await vi.advanceTimersByTimeAsync(1);
    });
    expect(list.queryFn).toHaveBeenCalledTimes(2);

    act(() => setVisibility("hidden"));
    await act(async () => {
      await vi.advanceTimersByTimeAsync(90_000);
    });
    expect(list.queryFn).toHaveBeenCalledTimes(2);

    act(() => setVisibility("visible"));
    await act(async () => {
      await vi.advanceTimersByTimeAsync(30_000);
    });
    expect(list.queryFn).toHaveBeenCalledTimes(3);

    unmount();
    list.unsubscribe();
  });

  it("clears its timers and listeners on unmount", () => {
    const qc = new QueryClient();
    const spy = vi.spyOn(qc, "invalidateQueries");
    const refetch = vi.spyOn(qc, "refetchQueries");
    const { unmount } = mount(qc);
    act(() => {
      channel().error();
      channel().emit("changed", changed());
    });

    unmount();
    expect(vi.getTimerCount()).toBe(0);
    act(() => {
      setVisibility("visible");
      vi.advanceTimersByTime(60_000);
    });
    expect(spy).not.toHaveBeenCalled();
    expect(refetch).not.toHaveBeenCalled();
  });

  it("opens a fresh channel for the next consumer after a full cleanup", () => {
    const qc = new QueryClient();
    mount(qc).unmount();
    const next = mount(qc);

    expect(fakeSocket.channel).toHaveBeenCalledTimes(2);
    expect(next.result.current).toBe("connecting");
    next.unmount();
  });
});
