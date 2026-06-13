import { useMutation, useQueryClient } from "@tanstack/react-query";
import { toast } from "sonner";
import { ApiError, stopRun, retryRun } from "@/lib/api";
import { RUN_KEY } from "@/lib/queryClient";

export function useStopRun(identifier: string) {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: () => stopRun(identifier),
    onSuccess: () => {
      toast.success("Run stop requested");
      void qc.invalidateQueries({ queryKey: RUN_KEY(identifier) });
    },
    onError: (err) => {
      const code = err instanceof ApiError ? err.code : "unknown";
      toast.error(`Failed to stop run (${code})`);
    },
  });
}

export function useRetryRun(identifier: string) {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: () => retryRun(identifier),
    onSuccess: () => {
      toast.success("Retry scheduled");
      void qc.invalidateQueries({ queryKey: RUN_KEY(identifier) });
    },
    onError: (err) => {
      const code = err instanceof ApiError ? err.code : "unknown";
      toast.error(`Failed to retry run (${code})`);
    },
  });
}
