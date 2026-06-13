import { QueryClient } from "@tanstack/react-query";
import type { WorkRunFilters } from "@/types/contract";

export const queryClient = new QueryClient({
  defaultOptions: { queries: { retry: 1, refetchOnWindowFocus: false } },
});

export const DASHBOARD_KEY = ["dashboard"] as const;

export const PROJECT_SUMMARY_KEY = (slug: string) => ["project-summary", slug] as const;

export const WORK_RUNS_KEY = (slug: string, filters: WorkRunFilters) =>
  ["work-runs", slug, filters] as const;

export const RUN_KEY = (identifier: string) => ["run", identifier] as const;

export const RUN_STREAM_KEY = (identifier: string) => ["run-stream", identifier] as const;
