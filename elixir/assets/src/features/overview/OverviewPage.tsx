import { Alert, AlertDescription, AlertTitle } from "@/components/ui/alert";
import { Skeleton } from "@/components/ui/skeleton";
import { useDashboard } from "@/features/dashboard/useDashboard";
import { ActiveRuns } from "@/features/overview/components/ActiveRuns";
import { MetricCards } from "@/features/overview/components/MetricCards";
import { NeedsAttention } from "@/features/overview/components/NeedsAttention";
import { ProjectHealthGrid } from "@/features/overview/components/ProjectHealthGrid";
import { RecentActivity } from "@/features/overview/components/RecentActivity";

export function OverviewPage() {
  const { data, isLoading } = useDashboard();

  if (isLoading && !data) {
    return (
      <div className="space-y-6">
        <Skeleton className="h-24 w-full" />
        <Skeleton className="h-48 w-full" />
      </div>
    );
  }
  if (!data) return <p className="text-muted-foreground">No data.</p>;

  return (
    <div className="space-y-6">
      <h1 className="text-2xl font-semibold">Overview</h1>

      {data.error ? (
        <Alert variant="destructive">
          <AlertTitle>{data.error.code}</AlertTitle>
          <AlertDescription>{data.error.message}</AlertDescription>
        </Alert>
      ) : null}

      <MetricCards state={data} />
      <NeedsAttention state={data} />
      <ActiveRuns rows={data.running ?? []} />

      <section className="space-y-2">
        <h2 className="text-lg font-medium">Projects</h2>
        <ProjectHealthGrid projects={data.projects ?? []} />
      </section>

      <RecentActivity events={data.durable?.work_events ?? []} />
    </div>
  );
}
