import { useEffect } from "react";
import { Link } from "react-router-dom";
import { Cpu } from "lucide-react";
import { Alert, AlertDescription, AlertTitle } from "@/components/ui/alert";
import { buttonVariants } from "@/components/ui/button";
import { Skeleton } from "@/components/ui/skeleton";
import { useDashboard } from "@/features/dashboard/useDashboard";
import { ActiveRuns } from "@/features/overview/components/ActiveRuns";
import { IntakeDiagnostics } from "@/features/overview/components/IntakeDiagnostics";
import { MetricCards } from "@/features/overview/components/MetricCards";
import { NeedsAttention } from "@/features/overview/components/NeedsAttention";
import { ProjectHealthGrid } from "@/features/overview/components/ProjectHealthGrid";
import { RecentActivity } from "@/features/overview/components/RecentActivity";
import { cn } from "@/lib/utils";

// Diagnostyka (spec §4.3, §12): the kept technical overview of agent runs plus
// the Jira intake metrics; the sandbox and rate limits live on /runtime.
export function OverviewPage() {
  const { data, isLoading } = useDashboard();

  useEffect(() => {
    document.title = "Diagnostyka — Harmony";
  }, []);

  if (isLoading && !data) {
    return (
      <div aria-label="Wczytywanie diagnostyki" className="space-y-6">
        <Skeleton className="h-24 w-full" />
        <Skeleton className="h-48 w-full" />
      </div>
    );
  }

  if (!data) return <p className="text-muted-foreground">Brak danych.</p>;

  return (
    <div className="space-y-6">
      <div className="flex items-center justify-between gap-[18px] max-[600px]:flex-wrap max-[600px]:gap-2.5">
        <div className="min-w-0">
          <h1 className="text-title max-[1150px]:text-[26px] max-[600px]:text-[27px]">Diagnostyka</h1>
          <p className="mt-2 text-xs leading-[1.6] text-muted-foreground">
            Stan przebiegów agentów, kolejek intake Jira i ostatniej aktywności.
          </p>
        </div>
        <Link to="/runtime" className={cn(buttonVariants({ variant: "outline" }), "max-[600px]:w-full")}>
          <Cpu aria-hidden strokeWidth={1.6} />
          Środowisko uruchomieniowe
        </Link>
      </div>
      {data.error ? (
        <Alert variant="destructive">
          <AlertTitle>{data.error.code}</AlertTitle>
          <AlertDescription>{data.error.message}</AlertDescription>
        </Alert>
      ) : null}
      <MetricCards state={data} />
      <NeedsAttention state={data} />
      <ActiveRuns rows={data.running ?? []} />
      <IntakeDiagnostics value={data.intake} />
      <section className="space-y-2">
        <h2 className="text-[17px] font-semibold">Projekty</h2>
        <ProjectHealthGrid projects={data.projects ?? []} />
      </section>
      <RecentActivity events={data.durable?.work_events ?? []} />
    </div>
  );
}
