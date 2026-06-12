import { useState } from "react";
import { useParams, Link } from "react-router-dom";
import { Alert, AlertDescription, AlertTitle } from "@/components/ui/alert";
import { Skeleton } from "@/components/ui/skeleton";
import { Button } from "@/components/ui/button";
import { useProjectSummary } from "@/features/project/useProjectSummary";
import { WorkTab } from "@/features/project/WorkTab";
import { projectHealth } from "@/lib/health";
import { ApiError } from "@/lib/api";

type Tab = "work" | "evidence" | "activity" | "configuration";

const healthDotClass: Record<string, string> = {
  healthy: "bg-green-500",
  retrying: "bg-yellow-500",
  blocked: "bg-red-500",
  idle: "bg-muted-foreground",
};

export function ProjectWorkspacePage() {
  const { slug } = useParams<{ slug: string }>();
  const [activeTab] = useState<Tab>("work");

  const { data: summary, isLoading, error, refetch } = useProjectSummary(slug!);

  if (isLoading && !summary) {
    return (
      <div className="space-y-4">
        <Skeleton className="h-10 w-48" />
        <Skeleton className="h-8 w-64" />
        <Skeleton className="h-64 w-full" />
      </div>
    );
  }

  if (error) {
    if (error instanceof ApiError && error.status === 404) {
      return (
        <div className="flex flex-col items-center justify-center gap-4 py-24 text-center">
          <h1 className="text-2xl font-semibold">Project not found</h1>
          <p className="text-muted-foreground">
            No project with slug <span className="font-mono">{slug}</span> exists.
          </p>
          <Link to="/projects" className="text-sm underline underline-offset-2">
            Back to projects
          </Link>
        </div>
      );
    }

    return (
      <Alert variant="destructive">
        <AlertTitle>Failed to load project</AlertTitle>
        <AlertDescription>{error.message}</AlertDescription>
        <div className="mt-2">
          <Button variant="outline" size="sm" onClick={() => void refetch()}>
            Retry
          </Button>
        </div>
      </Alert>
    );
  }

  if (!summary) return null;

  const health = projectHealth(summary.counts);
  const { running, retrying, blocked } = summary.counts;

  const tabs: { id: Tab; label: string; disabled: boolean }[] = [
    { id: "work", label: "Work", disabled: false },
    { id: "evidence", label: "Evidence", disabled: true },
    { id: "activity", label: "Activity", disabled: true },
    { id: "configuration", label: "Configuration", disabled: true },
  ];

  return (
    <div className="space-y-6">
      {/* Header */}
      <div className="space-y-1">
        <div className="flex items-center gap-2">
          <span
            className={`inline-block h-2.5 w-2.5 rounded-full ${healthDotClass[health] ?? "bg-muted-foreground"}`}
            aria-hidden="true"
          />
          <h1 className="text-2xl font-semibold">{summary.project.slug}</h1>
          <span className="sr-only">{health}</span>
        </div>
        <p className="font-mono text-sm text-muted-foreground">
          {running} running · {retrying} retrying · {blocked} blocked
        </p>
      </div>

      {/* Tab bar */}
      <div className="flex gap-1 border-b pb-px">
        {tabs.map((tab) => (
          <Button
            key={tab.id}
            variant={activeTab === tab.id ? "secondary" : "ghost"}
            size="sm"
            disabled={tab.disabled}
            title={tab.disabled ? "Coming soon" : undefined}
            className="rounded-b-none"
          >
            {tab.label}
          </Button>
        ))}
      </div>

      {/* Active tab content */}
      {activeTab === "work" && <WorkTab summary={summary} slug={slug!} />}
    </div>
  );
}
