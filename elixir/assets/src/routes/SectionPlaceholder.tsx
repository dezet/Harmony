import { useEffect, type ReactNode } from "react";
import { Link, useSearchParams } from "react-router-dom";
import { Skeleton } from "@/components/ui/skeleton";
import { useProjects } from "@/features/projects/useProjects";

// Reserved routes of layout A. The content arrives with the Case Center list
// (T21), automations (T24) and integrations (T25); until then the pages show
// only their heading and never sample data.

function PageTitle({ title, children }: { title: string; children?: ReactNode }) {
  useEffect(() => {
    document.title = `${title} — Harmony`;
  }, [title]);

  return (
    <div className="mb-[23px]">
      <h1 className="text-title">{title}</h1>
      {children ? <div className="mt-2 text-xs leading-[1.6] text-muted-foreground">{children}</div> : null}
    </div>
  );
}

export function SectionPlaceholder({ title, description }: { title: string; description: string }) {
  return <PageTitle title={title}>{description}</PageTitle>;
}

const CASE_CENTER_DESCRIPTION = "Wiesz, co się dzieje. Widzisz, co zrobić dalej.";

export function CaseCenterPlaceholder() {
  const [params] = useSearchParams();
  const slug = params.get("project");
  const projects = useProjects();

  if (!slug) return <PageTitle title="Centrum spraw">{CASE_CENTER_DESCRIPTION}</PageTitle>;
  if (projects.isPending) return <Skeleton className="h-9 w-64" />;
  if (projects.isError) {
    return <PageTitle title="Centrum spraw">Nie udało się wczytać projektów.</PageTitle>;
  }

  const project = projects.data.find((p) => p.slug === slug);
  if (!project) {
    return (
      <PageTitle title="Nie znaleziono projektu">
        <p>Projekt „{slug}” nie istnieje.</p>
        <Link className="text-primary underline underline-offset-4" to="/projects">
          Wszystkie projekty
        </Link>
      </PageTitle>
    );
  }

  return (
    <PageTitle title={project.display_name || project.slug}>
      <p>{CASE_CENTER_DESCRIPTION}</p>
      <Link className="text-primary underline underline-offset-4" to={`/projects/${encodeURIComponent(project.slug)}`}>
        Praca agentów i ustawienia
      </Link>
    </PageTitle>
  );
}
