import { useInfiniteQuery } from "@tanstack/react-query";
import { getProjectActivity } from "@/lib/api";
import { ACTIVITY_KEY } from "@/lib/queryClient";

export function useProjectActivity(slug: string) {
  return useInfiniteQuery({
    queryKey: ACTIVITY_KEY(slug),
    queryFn: ({ pageParam }) => getProjectActivity(slug, pageParam),
    getNextPageParam: (last) => last.meta.next_cursor ?? undefined,
    initialPageParam: undefined as string | undefined,
  });
}
