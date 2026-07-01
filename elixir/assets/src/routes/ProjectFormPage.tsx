import { Link, useNavigate, useParams } from "react-router-dom";
import { useProject } from "@/features/projects/useProjects";
import { Alert, AlertDescription, AlertTitle } from "@/components/ui/alert";
import { Button } from "@/components/ui/button";
import { Skeleton } from "@/components/ui/skeleton";
import { ProjectConfigForm } from "@/features/project/components/ProjectConfigForm";
import { ApiError } from "@/lib/api";

export function ProjectFormPage() {
  const { id } = useParams();
  const navigate = useNavigate();
  const editing = !!id;
  const {
    data: project,
    isLoading: isProjectLoading,
    isError: isProjectError,
    error: projectError,
  } = useProject(id);

  if (editing && isProjectLoading) {
    return (
      <div className="max-w-xl space-y-4">
        <h1 className="text-2xl font-semibold">Edit project</h1>
        <Skeleton className="h-96 w-full" />
      </div>
    );
  }

  if (editing && isProjectError) {
    const message =
      projectError instanceof ApiError
        ? projectError.message
        : projectError instanceof Error
          ? projectError.message
          : "Unexpected error";

    return (
      <div className="max-w-xl space-y-4">
        <h1 className="text-2xl font-semibold">Edit project</h1>
        <Alert variant="destructive">
          <AlertTitle>Could not load project</AlertTitle>
          <AlertDescription>{message}</AlertDescription>
        </Alert>
        <Button variant="outline" render={<Link to="/projects">Back to projects</Link>} />
      </div>
    );
  }

  return (
    <div className="max-w-xl space-y-4">
      <h1 className="text-2xl font-semibold">{editing ? "Edit project" : "New project"}</h1>
      <ProjectConfigForm
        project={editing ? project : undefined}
        onSuccess={() => navigate("/projects")}
      />
    </div>
  );
}
