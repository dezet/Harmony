import { useCallback, useEffect, useMemo, useState } from "react";
import { useSearchParams } from "react-router-dom";
import type { CaseFilters, CaseListFilter } from "@/types/contract";

// Reproducible Case Center state (spec §4.3): `/?project=&view=&filter=&q=&case=&tab=`.
// The URL is the source of truth; an invalid enum is replaced by its default
// without a new history entry. Cursors never enter the URL: they belong to the
// page of one filter set, so a new project/filter/search starts from page one.
// The only thing kept in localStorage is the Lista/Kanban preference, and an
// explicit `view` in the URL wins over it.

export type CaseView = "list" | "kanban";
export type CaseTab = "analysis" | "issue" | "history";

export const CASE_VIEW_STORAGE_KEY = "harmony.case-view.v1";
export const SEARCH_DEBOUNCE_MS = 300;
export const MAX_SEARCH_LENGTH = 200;

const VIEWS: readonly string[] = ["list", "kanban"] satisfies CaseView[];
const FILTERS: readonly string[] = ["all", "decision", "analysis", "done"] satisfies CaseListFilter[];
const TABS: readonly string[] = ["analysis", "issue", "history"] satisfies CaseTab[];

const ENUM_PARAMS: [string, readonly string[]][] = [
  ["view", VIEWS],
  ["filter", FILTERS],
  ["tab", TABS],
];

export interface CaseUrlState {
  project: string | null;
  view: CaseView;
  filter: CaseListFilter;
  q: string;
  caseRef: string | null;
  tab: CaseTab;
}

/** Search as sent to the API: trimmed and at most 200 characters. */
export function normalizeSearch(value: string): string {
  return value.trim().slice(0, MAX_SEARCH_LENGTH).trim();
}

/** The canonical form of `params`, or null when they already are canonical. */
export function canonicalCaseParams(params: URLSearchParams): URLSearchParams | null {
  const next = new URLSearchParams(params);
  let changed = false;

  for (const [key, allowed] of ENUM_PARAMS) {
    const value = next.get(key);
    if (value !== null && !allowed.includes(value)) {
      next.delete(key);
      changed = true;
    }
  }

  const q = next.get("q");
  if (q !== null) {
    const normalized = normalizeSearch(q);
    if (normalized !== q) {
      if (normalized) next.set("q", normalized);
      else next.delete("q");
      changed = true;
    }
  }

  for (const key of ["project", "case"]) {
    if (next.get(key) === "") {
      next.delete(key);
      changed = true;
    }
  }

  return changed ? next : null;
}

function isView(value: unknown): value is CaseView {
  return typeof value === "string" && VIEWS.includes(value);
}

/** Stored Lista/Kanban preference; null when absent, corrupt or storage is unavailable. */
export function readStoredView(): CaseView | null {
  try {
    const value = window.localStorage.getItem(CASE_VIEW_STORAGE_KEY);
    return isView(value) ? value : null;
  } catch {
    return null;
  }
}

export function storeView(view: CaseView): void {
  try {
    window.localStorage.setItem(CASE_VIEW_STORAGE_KEY, view);
  } catch {
    // Storage blocked or full: the view still lives in the URL.
  }
}

export function useCaseFilters() {
  const [params, setParams] = useSearchParams();
  const [storedView, setStoredView] = useState(readStoredView);
  const canonical = useMemo(() => canonicalCaseParams(params), [params]);

  useEffect(() => {
    if (canonical) setParams(canonical, { replace: true });
  }, [canonical, setParams]);

  const source = canonical ?? params;
  const project = source.get("project");
  const filter = (source.get("filter") ?? "all") as CaseListFilter;
  const q = source.get("q") ?? "";
  const explicitView = source.get("view") as CaseView | null;
  const caseRef = source.get("case");
  const tab = (source.get("tab") ?? "analysis") as CaseTab;
  const view = explicitView ?? storedView ?? "list";

  // Stats count the project only; filter badges and the list follow project
  // and search (spec §4.4). Without a search or filter both are one query.
  const listFilters = useMemo<CaseFilters>(() => {
    const filters: CaseFilters = {};
    if (project) filters.project = project;
    if (filter !== "all") filters.filter = filter;
    if (q) filters.q = q;
    return filters;
  }, [project, filter, q]);

  const statsFilters = useMemo<CaseFilters>(() => (project ? { project } : {}), [project]);

  const update = useCallback(
    (mutate: (next: URLSearchParams) => void, replace = false) => {
      setParams(
        (previous) => {
          const next = new URLSearchParams(previous);
          mutate(next);
          return next;
        },
        { replace },
      );
    },
    [setParams],
  );

  const setFilter = useCallback(
    (next: CaseListFilter) =>
      update((search) => {
        if (next === "all") search.delete("filter");
        else search.set("filter", next);
      }),
    [update],
  );

  const setQuery = useCallback(
    (value: string) =>
      update((search) => {
        const normalized = normalizeSearch(value);
        if (normalized) search.set("q", normalized);
        else search.delete("q");
      }),
    [update],
  );

  const setView = useCallback(
    (next: CaseView) => {
      storeView(next);
      setStoredView(next);
      update((search) => search.set("view", next));
    },
    [update],
  );

  const selectCase = useCallback(
    (ref: string | null, options: { replace?: boolean } = {}) =>
      update((search) => {
        if (ref) search.set("case", ref);
        else search.delete("case");
      }, options.replace),
    [update],
  );

  const setTab = useCallback(
    (next: CaseTab) =>
      update((search) => {
        if (next === "analysis") search.delete("tab");
        else search.set("tab", next);
      }, true),
    [update],
  );

  const clearFilters = useCallback(
    () =>
      update((search) => {
        search.delete("filter");
        search.delete("q");
        search.delete("case");
      }),
    [update],
  );

  const state: CaseUrlState = { project, view, filter, q, caseRef, tab };

  return { state, listFilters, statsFilters, setFilter, setQuery, setView, selectCase, setTab, clearFilters };
}

/**
 * Local text of the search box. Typing commits the normalized value after
 * 300 ms of silence; a URL change from elsewhere (Back/Forward, "Wyczyść
 * filtry") replaces the draft unless it already matches the new search.
 */
export function useSearchDraft(q: string, commit: (value: string) => void) {
  const [draft, setDraft] = useState(q);
  const [syncedQ, setSyncedQ] = useState(q);

  if (syncedQ !== q) {
    setSyncedQ(q);
    if (normalizeSearch(draft) !== q) setDraft(q);
  }

  useEffect(() => {
    const next = normalizeSearch(draft);
    if (next === q) return;
    const timer = setTimeout(() => commit(next), SEARCH_DEBOUNCE_MS);
    return () => clearTimeout(timer);
  }, [draft, q, commit]);

  return [draft, setDraft] as const;
}
