import { Link } from "react-router-dom";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { projectHealth, type ProjectHealth } from "@/lib/health";
import { cn } from "@/lib/utils";
import type { ProjectCounts, ProjectRef } from "@/types/contract";

const healthStyles: Record<ProjectHealth, string> = {
  healthy: "bg-emerald-500",
  retrying: "bg-amber-500",
  blocked: "bg-red-500",
  idle: "bg-muted-foreground/40",
};

export function ProjectHealthGrid({
  projects,
}: {
  projects: Array<ProjectRef & { counts: ProjectCounts }>;
}) {
  if (projects.length === 0) {
    return (
      <p className="text-sm text-muted-foreground">
        No projects configured yet.{" "}
        <Link className="underline underline-offset-4 hover:text-foreground" to="/projects/new">
          Create the first one.
        </Link>
      </p>
    );
  }

  return (
    <div className="grid gap-4 sm:grid-cols-2 lg:grid-cols-3">
      {projects.map((p) => {
        const health = projectHealth(p.counts);
        return (
          <Card key={p.id ?? p.slug ?? p.name ?? "unknown"}>
            <CardHeader>
              <CardTitle className="flex items-center gap-2 text-base">
                <span aria-hidden title={health} className={cn("size-2.5 rounded-full", healthStyles[health])} />
                <span className="truncate">{p.slug ?? p.name ?? "unnamed"}</span>
              </CardTitle>
            </CardHeader>
            <CardContent className="flex gap-4 font-mono text-sm text-muted-foreground">
              <span>{p.counts.running} running</span>
              <span>{p.counts.retrying} retrying</span>
              <span>{p.counts.blocked} blocked</span>
            </CardContent>
          </Card>
        );
      })}
    </div>
  );
}
