import { useEffect } from "react";
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

  useEffect(() => {
    document.title = `${editing ? "Edycja projektu" : "Nowy projekt"} — Harmony`;
  }, [editing]);

  if (editing && isProjectLoading) {
    return (
      <div className="max-w-xl space-y-4">
        <h1 className="text-title">Edycja projektu</h1>
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
          : "Nieoczekiwany błąd";

    return (
      <div className="max-w-xl space-y-4">
        <h1 className="text-title">Edycja projektu</h1>
        <Alert variant="destructive">
          <AlertTitle>Nie udało się wczytać projektu</AlertTitle>
          <AlertDescription>{message}</AlertDescription>
        </Alert>
        <Button variant="outline" render={<Link to="/projects">Wróć do projektów</Link>} />
      </div>
    );
  }

  return (
    <div className="max-w-xl space-y-4">
      <h1 className="text-title">{editing ? "Edycja projektu" : "Nowy projekt"}</h1>
      <ProjectConfigForm
        project={editing ? project : undefined}
        onSuccess={() => navigate("/projects")}
      />
    </div>
  );
}
