import { useQuery } from "@tanstack/react-query";
import { getProjectSummary } from "@/lib/api";
import { PROJECT_SUMMARY_KEY } from "@/lib/queryClient";
import type { ProjectSummary } from "@/types/contract";

export function useProjectSummary(slug: string) {
  return useQuery<ProjectSummary>({
    queryKey: PROJECT_SUMMARY_KEY(slug),
    queryFn: () => getProjectSummary(slug),
    staleTime: 30_000,
  });
}
