import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { act, render, renderHook } from "@testing-library/react";
import { createElement } from "react";
import { createMemoryRouter, RouterProvider } from "react-router-dom";
import {
  CASE_VIEW_STORAGE_KEY,
  MAX_SEARCH_LENGTH,
  SEARCH_DEBOUNCE_MS,
  canonicalCaseParams,
  readStoredView,
  storeView,
  useCaseFilters,
  useSearchDraft,
} from "@/features/cases/useCaseFilters";

type Filters = ReturnType<typeof useCaseFilters>;

function setup(url: string) {
  let current: Filters | undefined;
  function Probe() {
    current = useCaseFilters();
    return null;
  }
  const router = createMemoryRouter([{ path: "/", element: createElement(Probe) }], {
    initialEntries: [url],
  });
  render(createElement(RouterProvider, { router }));
  return {
    router,
    get: () => {
      if (!current) throw new Error("hook not rendered");
      return current;
    },
    search: () => new URLSearchParams(router.state.location.search),
  };
}

beforeEach(() => {
  window.localStorage.clear();
});

afterEach(() => {
  vi.useRealTimers();
  vi.restoreAllMocks();
});

describe("canonicalCaseParams", () => {
  it("keeps a canonical query untouched", () => {
    expect(canonicalCaseParams(new URLSearchParams("project=hr&view=kanban&filter=done&q=OPS&case=jira_1&tab=history"))).toBeNull();
  });

  it("drops invalid enums and trims the search to 200 characters", () => {
    const long = ` ${"a".repeat(MAX_SEARCH_LENGTH + 20)} `;
    const next = canonicalCaseParams(
      new URLSearchParams({ project: "hr", view: "board", filter: "open", tab: "raw", q: long }),
    );
    expect(next?.get("project")).toBe("hr");
    expect(next?.has("view")).toBe(false);
    expect(next?.has("filter")).toBe(false);
    expect(next?.has("tab")).toBe(false);
    expect(next?.get("q")).toBe("a".repeat(MAX_SEARCH_LENGTH));
  });

  it("removes an empty search, project and case", () => {
    const next = canonicalCaseParams(new URLSearchParams("q=%20%20&project=&case="));
    expect(next?.toString()).toBe("");
  });
});

describe("useCaseFilters", () => {
  it("reads project, filter, search, case and tab from the URL", () => {
    const { get } = setup("/?project=portal-klienta&filter=decision&q=OPS-1&case=jira_1&tab=issue");
    const state = get().state;
    expect(state).toMatchObject({
      project: "portal-klienta",
      filter: "decision",
      q: "OPS-1",
      caseRef: "jira_1",
      tab: "issue",
      view: "list",
    });
    expect(get().listFilters).toEqual({ project: "portal-klienta", filter: "decision", q: "OPS-1" });
  });

  it("uses documented aggregation scopes: the list follows project+q+filter, stats only the project", () => {
    const { get } = setup("/?project=hr&filter=analysis&q=abc");
    expect(get().listFilters).toEqual({ project: "hr", filter: "analysis", q: "abc" });
    expect(get().statsFilters).toEqual({ project: "hr" });
  });

  it("shares one query between list and stats when no search or filter narrows the list", () => {
    const { get } = setup("/?project=hr&filter=all");
    expect(get().listFilters).toEqual(get().statsFilters);
    expect(setup("/").get().listFilters).toEqual({});
  });

  it("normalizes an invalid enum with a history replace, not a new entry", () => {
    const { router, search } = setup("/?view=grid&filter=open&project=hr");
    expect(router.state.historyAction).toBe("REPLACE");
    expect(search().toString()).toBe("project=hr");
  });

  it("pushes filter changes so Back and Forward restore them", async () => {
    const { router, get, search } = setup("/?project=hr&q=abc");
    act(() => get().setFilter("decision"));
    expect(router.state.historyAction).toBe("PUSH");
    expect(search().get("filter")).toBe("decision");
    expect(search().get("q")).toBe("abc");
    expect(search().get("project")).toBe("hr");

    act(() => get().setFilter("all"));
    expect(search().has("filter")).toBe(false);

    await act(() => router.navigate(-1));
    expect(get().state.filter).toBe("decision");
    await act(() => router.navigate(-1));
    expect(get().state.filter).toBe("all");
    await act(() => router.navigate(1));
    expect(get().state.filter).toBe("decision");
  });

  it("stores a normalized search and removes an empty one", () => {
    const { get, search } = setup("/?q=old");
    act(() => get().setQuery("  OPS-142  "));
    expect(search().get("q")).toBe("OPS-142");
    act(() => get().setQuery("   "));
    expect(search().has("q")).toBe(false);
  });

  it("clears filter, search and selection but keeps the project", () => {
    const { get, search } = setup("/?project=hr&filter=done&q=x&case=jira_1&view=list");
    act(() => get().clearFilters());
    expect(search().toString()).toBe("project=hr&view=list");
  });

  it("selects a case through the URL", () => {
    const { get, search } = setup("/?project=hr");
    act(() => get().selectCase("run_1"));
    expect(search().get("case")).toBe("run_1");
    act(() => get().selectCase(null));
    expect(search().has("case")).toBe(false);
  });
});

describe("case view preference", () => {
  it("falls back to the stored view when the URL has none", () => {
    window.localStorage.setItem(CASE_VIEW_STORAGE_KEY, "kanban");
    expect(setup("/").get().state.view).toBe("kanban");
  });

  it("lets an explicit URL view win over the stored preference", () => {
    window.localStorage.setItem(CASE_VIEW_STORAGE_KEY, "kanban");
    const { get } = setup("/?view=list");
    expect(get().state.view).toBe("list");
    expect(window.localStorage.getItem(CASE_VIEW_STORAGE_KEY)).toBe("kanban");
  });

  it("ignores a corrupt stored value", () => {
    window.localStorage.setItem(CASE_VIEW_STORAGE_KEY, "{\"items\":[]}");
    expect(readStoredView()).toBeNull();
    expect(setup("/").get().state.view).toBe("list");
  });

  it("writes the chosen view to the URL and only the view to storage", () => {
    const { get, search } = setup("/?project=hr&q=abc");
    act(() => get().setView("kanban"));
    expect(search().get("view")).toBe("kanban");
    expect(search().get("q")).toBe("abc");
    expect(get().state.view).toBe("kanban");
    expect(Object.keys(window.localStorage)).toEqual([CASE_VIEW_STORAGE_KEY]);
    expect(window.localStorage.getItem(CASE_VIEW_STORAGE_KEY)).toBe("kanban");
  });

  it("survives storage that throws on read and write", () => {
    vi.spyOn(Storage.prototype, "getItem").mockImplementation(() => {
      throw new Error("SecurityError");
    });
    vi.spyOn(Storage.prototype, "setItem").mockImplementation(() => {
      throw new Error("QuotaExceededError");
    });
    expect(readStoredView()).toBeNull();
    expect(() => storeView("kanban")).not.toThrow();

    const { get, search } = setup("/");
    expect(get().state.view).toBe("list");
    act(() => get().setView("kanban"));
    expect(search().get("view")).toBe("kanban");
  });
});

describe("useSearchDraft", () => {
  it(`commits the trimmed search only after ${SEARCH_DEBOUNCE_MS} ms of silence`, () => {
    vi.useFakeTimers();
    const commit = vi.fn();
    const { result } = renderHook(({ q }) => useSearchDraft(q, commit), { initialProps: { q: "" } });

    act(() => result.current[1]("OP"));
    act(() => vi.advanceTimersByTime(200));
    act(() => result.current[1]("OPS-1 "));
    act(() => vi.advanceTimersByTime(SEARCH_DEBOUNCE_MS - 1));
    expect(commit).not.toHaveBeenCalled();

    act(() => vi.advanceTimersByTime(1));
    expect(commit).toHaveBeenCalledTimes(1);
    expect(commit).toHaveBeenCalledWith("OPS-1");
  });

  it("does not commit when the draft only differs by whitespace", () => {
    vi.useFakeTimers();
    const commit = vi.fn();
    const { result } = renderHook(({ q }) => useSearchDraft(q, commit), { initialProps: { q: "abc" } });
    act(() => result.current[1]("abc  "));
    act(() => vi.advanceTimersByTime(SEARCH_DEBOUNCE_MS * 2));
    expect(commit).not.toHaveBeenCalled();
  });

  it("follows the URL on Back/Forward but keeps a trailing space while typing", () => {
    const commit = vi.fn();
    const { result, rerender } = renderHook(({ q }) => useSearchDraft(q, commit), { initialProps: { q: "" } });

    act(() => result.current[1]("abc "));
    rerender({ q: "abc" });
    expect(result.current[0]).toBe("abc ");

    rerender({ q: "OPS" });
    expect(result.current[0]).toBe("OPS");
  });
});
