import { useMemo } from "react";
import { useInfiniteQuery } from "@tanstack/react-query";
import { listCases } from "@/lib/api";
import { CASES_KEY } from "@/lib/queryClient";
import { useIntakeChannel } from "@/features/cases/useIntakeChannel";
import type { CaseColumn, CaseFilters } from "@/types/contract";

/** Kanban columns in their fixed order (spec §4.5). */
export const CASE_COLUMNS = ["detected", "analyzing", "decision", "handed_off"] as const satisfies readonly CaseColumn[];

/**
 * Case list pages (25 by default) for one set of filters. The key contains the
 * filters, so another project or filter never shows the previous request's
 * data; the request it replaces is aborted. Kept fresh by `intake:workspace`.
 */
export function useCases(filters: CaseFilters) {
  useIntakeChannel();

  return useInfiniteQuery({
    queryKey: CASES_KEY(filters),
    queryFn: ({ pageParam, signal }) => listCases(filters, pageParam, signal),
    getNextPageParam: (last) => last.meta.next_cursor ?? undefined,
    initialPageParam: undefined as string | undefined,
  });
}

/**
 * Pages of one Kanban column: the list's filters plus `column`. The column is
 * part of the query key, so each column keeps its own pages and cursor and
 * never shares them with the list or another column (spec §11.3).
 */
export function useCaseColumn(filters: CaseFilters, column: CaseColumn) {
  const columnFilters = useMemo<CaseFilters>(() => ({ ...filters, column }), [filters, column]);
  return useCases(columnFilters);
}
