import { useDashboard } from "@/features/dashboard/useDashboard";
import { useNow } from "@/lib/useNow";
import { MetricCards } from "@/features/dashboard/components/MetricCards";
import { RunningTable } from "@/features/dashboard/components/RunningTable";
import { RetryTable } from "@/features/dashboard/components/RetryTable";
import { BlockedTable } from "@/features/dashboard/components/BlockedTable";
import { ConnectionStatus } from "@/features/dashboard/components/ConnectionStatus";
import { RuntimeCard } from "@/features/dashboard/components/RuntimeCard";
import { ProjectsSummaryTable } from "@/features/dashboard/components/ProjectsSummaryTable";
import { WorkRunsTable } from "@/features/dashboard/components/WorkRunsTable";
import { ArtifactsTable } from "@/features/dashboard/components/ArtifactsTable";
import { RateLimits } from "@/features/dashboard/components/RateLimits";
import { Skeleton } from "@/components/ui/skeleton";
import { Alert, AlertTitle, AlertDescription } from "@/components/ui/alert";

export function DashboardPage() {
  const { data, isLoading } = useDashboard();
  const nowMs = useNow();
  const evidenceArtifacts = [...(data?.artifacts ?? []), ...(data?.durable?.artifacts ?? [])];

  return (
    <div className="space-y-6">
      <div className="flex items-center justify-between">
        <h1 className="text-2xl font-semibold">Dashboard</h1>
        <ConnectionStatus hasData={!!data} />
      </div>

      {isLoading && !data ? (
        <Skeleton className="h-32 w-full" />
      ) : data ? (
        <>
          {data.error ? (
            <Alert variant="destructive">
              <AlertTitle>{data.error.code}</AlertTitle>
              <AlertDescription>{data.error.message}</AlertDescription>
            </Alert>
          ) : null}

          <MetricCards state={data} />

          <section>
            <h2 className="text-lg font-medium mb-2">Running sessions</h2>
            <RunningTable rows={data.running ?? []} nowMs={nowMs} />
          </section>

          <section>
            <h2 className="text-lg font-medium mb-2">Retry queue</h2>
            <RetryTable rows={data.retrying ?? []} nowMs={nowMs} />
          </section>

          <section>
            <h2 className="text-lg font-medium mb-2">Blocked sessions</h2>
            <BlockedTable rows={data.blocked ?? []} />
          </section>

          {data.projects && data.projects.length > 0 ? (
            <section>
              <h2 className="text-lg font-medium mb-2">Projects</h2>
              <ProjectsSummaryTable rows={data.projects} />
            </section>
          ) : null}

          {data.runtime?.sandbox ? (
            <section>
              <h2 className="text-lg font-medium mb-2">Runtime</h2>
              <RuntimeCard sandbox={data.runtime.sandbox} />
            </section>
          ) : null}

          {data.durable?.work_runs ? (
            <section>
              <h2 className="text-lg font-medium mb-2">Work runs</h2>
              <WorkRunsTable rows={data.durable.work_runs} />
            </section>
          ) : null}

          {evidenceArtifacts.length > 0 ? (
            <section>
              <h2 className="text-lg font-medium mb-2">Evidence artifacts</h2>
              <ArtifactsTable rows={evidenceArtifacts} />
            </section>
          ) : null}

          {data.rate_limits != null ? (
            <section>
              <h2 className="text-lg font-medium mb-2">Rate limits</h2>
              <RateLimits value={data.rate_limits} />
            </section>
          ) : null}
        </>
      ) : (
        <p className="text-muted-foreground">No data.</p>
      )}
    </div>
  );
}
