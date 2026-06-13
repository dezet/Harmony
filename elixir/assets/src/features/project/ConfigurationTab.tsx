import { useQueryClient } from "@tanstack/react-query";
import { toast } from "sonner";
import { Alert, AlertDescription, AlertTitle } from "@/components/ui/alert";
import { Button } from "@/components/ui/button";
import { Skeleton } from "@/components/ui/skeleton";
import { useProject } from "@/features/projects/useProjects";
import { ProjectConfigForm } from "@/features/project/components/ProjectConfigForm";
import { PROJECT_SUMMARY_KEY } from "@/lib/queryClient";

interface ConfigurationTabProps {
  projectId: string;
  slug: string;
  active: boolean;
}

export function ConfigurationTab({ projectId, slug, active }: ConfigurationTabProps) {
  const queryClient = useQueryClient();
  const { data: project, isLoading, error, refetch } = useProject(projectId, { enabled: active });

  function handleSuccess() {
    toast.success("Configuration saved");
    void queryClient.invalidateQueries({ queryKey: PROJECT_SUMMARY_KEY(slug) });
  }

  if (active && isLoading) {
    return (
      <div className="space-y-4">
        <Skeleton className="h-10 w-full" />
        <Skeleton className="h-10 w-full" />
        <Skeleton className="h-10 w-full" />
        <Skeleton className="h-40 w-full" />
      </div>
    );
  }

  if (error) {
    const message = error instanceof Error ? error.message : "Unexpected error";
    return (
      <Alert variant="destructive">
        <AlertTitle>Failed to load configuration</AlertTitle>
        <AlertDescription>{message}</AlertDescription>
        <div className="mt-2">
          <Button variant="outline" size="sm" onClick={() => void refetch()}>
            Retry
          </Button>
        </div>
      </Alert>
    );
  }

  if (!project) return null;

  return <ProjectConfigForm project={project} onSuccess={handleSuccess} />;
}
