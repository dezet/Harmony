import { useQuery } from "@tanstack/react-query";
import { getRunDetail } from "@/lib/api";
import { RUN_KEY } from "@/lib/queryClient";

export function useRunDetail(identifier: string) {
  return useQuery({
    queryKey: RUN_KEY(identifier),
    queryFn: () => getRunDetail(identifier),
    staleTime: 30_000,
  });
}
