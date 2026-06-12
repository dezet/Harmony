import { useInfiniteQuery } from "@tanstack/react-query";
import { getWorkRuns } from "@/lib/api";
import { WORK_RUNS_KEY } from "@/lib/queryClient";
import type { WorkRunFilters, WorkRunsPage } from "@/types/contract";

export function useWorkRuns(slug: string, filters: WorkRunFilters) {
  return useInfiniteQuery<WorkRunsPage, Error, WorkRunsPage[], readonly unknown[], string | undefined>({
    queryKey: WORK_RUNS_KEY(slug, filters),
    queryFn: ({ pageParam }) => getWorkRuns(slug, filters, pageParam),
    getNextPageParam: (last) => last.meta.next_cursor ?? undefined,
    initialPageParam: undefined as string | undefined,
  });
}
