import { useEffect, type ReactNode } from "react";

// Reserved routes of layout A. The content arrives with automations (T24) and
// integrations (T25); until then the pages show only their heading and never
// sample data.

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
