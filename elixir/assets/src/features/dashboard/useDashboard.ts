import { useQuery } from "@tanstack/react-query";
import { getState } from "@/lib/api";
import { DASHBOARD_KEY } from "@/lib/queryClient";
import type { StatePayload } from "@/types/contract";

// Initial load + reconnect come from REST; live updates arrive via the channel
// (which writes the same cache key). staleTime Infinity = never auto-refetch.
export function useDashboard() {
  return useQuery<StatePayload>({
    queryKey: DASHBOARD_KEY,
    queryFn: getState,
    staleTime: Infinity,
  });
}
