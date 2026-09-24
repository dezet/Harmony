import { useInfiniteQuery } from "@tanstack/react-query";
import { listCases } from "@/lib/api";
import { CASES_KEY } from "@/lib/queryClient";
import { useIntakeChannel } from "@/features/cases/useIntakeChannel";
import type { CaseFilters } from "@/types/contract";

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
