import { useInfiniteQuery } from "@tanstack/react-query";
import { getRunStream } from "@/lib/api";
import { RUN_STREAM_KEY } from "@/lib/queryClient";

export function useRunStream(identifier: string) {
  return useInfiniteQuery({
    queryKey: RUN_STREAM_KEY(identifier),
    queryFn: ({ pageParam }) => getRunStream(identifier, pageParam),
    getNextPageParam: (last) => last.meta.next_cursor ?? undefined,
    initialPageParam: undefined as string | undefined,
  });
}
