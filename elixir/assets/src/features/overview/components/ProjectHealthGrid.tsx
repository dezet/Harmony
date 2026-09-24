import { Link } from "react-router-dom";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { projectHealth, type ProjectHealth } from "@/lib/health";
import { cn } from "@/lib/utils";
import type { ProjectCounts, ProjectRef } from "@/types/contract";

// Health of the agent runs; unrelated to the project identity color.
const healthStyles: Record<ProjectHealth, string> = {
  healthy: "bg-success",
  retrying: "bg-warning",
  blocked: "bg-destructive",
  idle: "bg-muted-foreground/40",
};

const healthLabels: Record<ProjectHealth, string> = {
  healthy: "w toku",
  retrying: "ponawia",
  blocked: "zablokowany",
  idle: "bezczynny",
};

export function ProjectHealthGrid({
  projects,
}: {
  projects: Array<ProjectRef & { counts: ProjectCounts }>;
}) {
  if (projects.length === 0) {
    return (
      <p className="text-sm text-muted-foreground">
        Nie skonfigurowano jeszcze projektów.{" "}
        <Link className="underline underline-offset-4 hover:text-foreground" to="/projects/new">
          Utwórz pierwszy projekt.
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
                <span aria-hidden className={cn("size-2.5 rounded-full", healthStyles[health])} />
                <span className="truncate">{p.slug ?? p.name ?? "bez nazwy"}</span>
                <span className="sr-only">({healthLabels[health]})</span>
              </CardTitle>
            </CardHeader>
            <CardContent className="flex gap-4 font-mono text-sm text-muted-foreground">
              <span>w toku: {p.counts.running}</span>
              <span>ponawiane: {p.counts.retrying}</span>
              <span>zablokowane: {p.counts.blocked}</span>
            </CardContent>
          </Card>
        );
      })}
    </div>
  );
}
