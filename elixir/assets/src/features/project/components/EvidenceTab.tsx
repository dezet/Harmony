import { Alert, AlertDescription, AlertTitle } from "@/components/ui/alert";
import { Button } from "@/components/ui/button";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { Skeleton } from "@/components/ui/skeleton";
import { ElapsedTime } from "@/components/ElapsedTime";
import { StatusBadge } from "@/components/StatusBadge";
import { getArtifactUrl } from "@/lib/api";
import { useProjectArtifacts } from "@/features/project/useProjectArtifacts";
import type { ProjectArtifact } from "@/types/contract";

interface EvidenceTabProps {
  slug: string;
}

function groupByWorkRunId(artifacts: ProjectArtifact[]): Map<string | null, ProjectArtifact[]> {
  const groups = new Map<string | null, ProjectArtifact[]>();
  for (const artifact of artifacts) {
    const key = artifact.work_run_id;
    const existing = groups.get(key);
    if (existing) {
      existing.push(artifact);
    } else {
      groups.set(key, [artifact]);
    }
  }
  return groups;
}

function ArtifactRow({ artifact }: { artifact: ProjectArtifact }) {
  const url = getArtifactUrl(artifact.id);

  if (artifact.kind === "screenshot") {
    return (
      <div className="flex flex-col gap-1">
        <a href={url} target="_blank" rel="noreferrer">
          <img
            src={url}
            alt={artifact.kind}
            className="max-h-40 rounded border"
          />
        </a>
      </div>
    );
  }

  const description =
    typeof artifact.metadata?.description === "string"
      ? artifact.metadata.description
      : artifact.id;

  return (
    <div>
      <a
        href={url}
        download
        className="text-sm underline underline-offset-2 hover:opacity-80"
      >
        {artifact.kind} — {description}
      </a>
    </div>
  );
}

export function EvidenceTab({ slug }: EvidenceTabProps) {
  const { data, isLoading, error, refetch } = useProjectArtifacts(slug);

  if (isLoading) {
    return (
      <div className="space-y-4">
        <Skeleton className="h-32 w-full" />
        <Skeleton className="h-32 w-full" />
      </div>
    );
  }

  if (error) {
    return (
      <Alert variant="destructive">
        <AlertTitle>Error loading evidence</AlertTitle>
        <AlertDescription>{error.message}</AlertDescription>
        <div className="mt-2">
          <Button variant="outline" size="sm" onClick={() => void refetch()}>
            Retry
          </Button>
        </div>
      </Alert>
    );
  }

  const artifacts = data?.artifacts ?? [];

  if (artifacts.length === 0) {
    return <p className="text-muted-foreground">No evidence yet.</p>;
  }

  const groups = groupByWorkRunId(artifacts);

  return (
    <div className="space-y-4">
      {Array.from(groups.entries()).map(([workRunId, groupArtifacts]) => {
        // All artifacts in a group share the same work_run (take from first)
        const workRun = groupArtifacts[0]?.work_run ?? null;
        const groupKey = workRunId ?? "unattached";

        return (
          <Card key={groupKey}>
            <CardHeader>
              <CardTitle className="flex items-center gap-2 flex-wrap">
                <span className="font-mono">
                  {workRun?.linear_identifier ?? "—"}
                </span>
                {workRun && (
                  <>
                    <StatusBadge status={workRun.status} />
                    <ElapsedTime since={workRun.inserted_at} />
                  </>
                )}
                {!workRun && (
                  <span className="text-muted-foreground text-sm font-normal">
                    Unattached
                  </span>
                )}
              </CardTitle>
            </CardHeader>
            <CardContent className="space-y-2">
              {groupArtifacts.map((artifact) => (
                <ArtifactRow key={artifact.id} artifact={artifact} />
              ))}
            </CardContent>
          </Card>
        );
      })}
    </div>
  );
}
