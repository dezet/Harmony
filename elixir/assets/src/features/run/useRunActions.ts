import { useMutation, useQueryClient } from "@tanstack/react-query";
import { toast } from "sonner";
import { ApiError, stopRun, retryRun } from "@/lib/api";
import { RUN_KEY } from "@/lib/queryClient";

export function useStopRun(identifier: string) {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: () => stopRun(identifier),
    onSuccess: () => {
      toast.success("Zażądano zatrzymania przebiegu");
      void qc.invalidateQueries({ queryKey: RUN_KEY(identifier) });
    },
    onError: (err) => {
      const code = err instanceof ApiError ? err.code : "unknown";
      toast.error(`Nie udało się zatrzymać przebiegu (${code})`);
    },
  });
}

export function useRetryRun(identifier: string) {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: () => retryRun(identifier),
    onSuccess: () => {
      toast.success("Zaplanowano ponowienie");
      void qc.invalidateQueries({ queryKey: RUN_KEY(identifier) });
    },
    onError: (err) => {
      const code = err instanceof ApiError ? err.code : "unknown";
      toast.error(`Nie udało się ponowić przebiegu (${code})`);
    },
  });
}
