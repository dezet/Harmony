import { useQuery } from "@tanstack/react-query";
import { getProjectArtifacts } from "@/lib/api";
import { ARTIFACTS_KEY } from "@/lib/queryClient";

export function useProjectArtifacts(slug: string) {
  return useQuery({
    queryKey: ARTIFACTS_KEY(slug),
    queryFn: () => getProjectArtifacts(slug),
    staleTime: 30_000,
  });
}
