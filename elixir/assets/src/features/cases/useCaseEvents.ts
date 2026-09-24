import { useInfiniteQuery } from "@tanstack/react-query";
import { listCaseEvents } from "@/lib/api";
import { CASE_EVENTS_KEY } from "@/lib/queryClient";
import { useIntakeChannel } from "@/features/cases/useIntakeChannel";

/** Case history pages (50 per page); idle without a ref. */
export function useCaseEvents(ref: string | undefined) {
  useIntakeChannel();

  return useInfiniteQuery({
    queryKey: CASE_EVENTS_KEY(ref ?? ""),
    queryFn: ({ pageParam, signal }) => listCaseEvents(ref as string, pageParam, signal),
    getNextPageParam: (last) => last.meta.next_cursor ?? undefined,
    initialPageParam: undefined as string | undefined,
    enabled: Boolean(ref),
  });
}
