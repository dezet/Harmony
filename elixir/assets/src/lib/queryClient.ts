import { QueryClient } from "@tanstack/react-query";
import type { AutomationFilters, CaseFilters, WorkRunFilters } from "@/types/contract";

export const queryClient = new QueryClient({
  defaultOptions: { queries: { retry: 1, refetchOnWindowFocus: false } },
});

export const DASHBOARD_KEY = ["dashboard"] as const;

export const PROJECT_SUMMARY_KEY = (slug: string) => ["project-summary", slug] as const;

export const WORK_RUNS_KEY = (slug: string, filters: WorkRunFilters) =>
  ["work-runs", slug, filters] as const;

export const RUN_KEY = (identifier: string) => ["run", identifier] as const;

export const RUN_STREAM_KEY = (identifier: string) => ["run-stream", identifier] as const;

export const ARTIFACTS_KEY = (slug: string) => ["artifacts", slug] as const;

export const ACTIVITY_KEY = (slug: string) => ["activity", slug] as const;

// Case Center and intake configuration (spec §11.4). Invalidated by the
// `intake:workspace` channel; the keys above belong to observability and are
// never touched by it.
export const CASES_KEY = (filters: CaseFilters) => ["cases", filters] as const;

export const CASE_KEY = (ref: string) => ["case", ref] as const;

export const CASE_EVENTS_KEY = (ref: string) => ["case-events", ref] as const;

export const AUTOMATIONS_KEY = (filters: AutomationFilters) => ["automations", filters] as const;

export const AUTOMATION_KEY = (id: string) => ["automation", id] as const;

export const INTEGRATIONS_KEY = ["integrations"] as const;

export const INTAKE_QUERY_ROOTS: readonly string[] = [
  "cases",
  "case",
  "case-events",
  "automations",
  "automation",
  "integrations",
];
