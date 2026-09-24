import { useQuery } from "@tanstack/react-query";
import { getCase } from "@/lib/api";
import { CASE_KEY } from "@/lib/queryClient";
import { useIntakeChannel } from "@/features/cases/useIntakeChannel";

/** Case detail for `jira_<uuid>` or `run_<uuid>`; idle without a ref. */
export function useCase(ref: string | undefined) {
  useIntakeChannel();

  return useQuery({
    queryKey: CASE_KEY(ref ?? ""),
    queryFn: ({ signal }) => getCase(ref as string, signal),
    enabled: Boolean(ref),
  });
}
