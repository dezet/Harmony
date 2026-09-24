import type { CSSProperties, ReactNode } from "react";
import { Activity, Inbox, LayoutGrid, Link2, Zap, type LucideIcon } from "lucide-react";
import { Link, useLocation } from "react-router-dom";
import { ThemeToggle } from "@/components/theme/ThemeToggle";
import { useCases } from "@/features/cases/useCases";
import { useProjects } from "@/features/projects/useProjects";
import { useDashboardConnection, type DashboardConnectionStatus } from "@/lib/dashboardConnection";
import { cn } from "@/lib/utils";
import type { Project } from "@/types/contract";

// Sidebar of layout A (spec §4.2). A project's color is its identity only and
// never encodes health; its badge counts every projected case of the project.

// One small page is enough: `project_counts` and `counts` are aggregates over
// the whole projection, independent of the items returned.
const TOTALS_FILTERS = { page_size: 1 } as const;
const BADGE_CAP = 999;
const casePlural = new Intl.PluralRules("pl-PL");

const connectionLabels: Record<DashboardConnectionStatus, string> = {
  connecting: "Łączenie…",
  live: "Połączono",
  reconnecting: "Ponowne łączenie…",
  offline: "Brak połączenia",
};

const connectionDots: Record<DashboardConnectionStatus, string> = {
  connecting: "bg-warning",
  live: "bg-success",
  reconnecting: "bg-warning",
  offline: "bg-destructive",
};

const navItem =
  "flex min-h-[39px] items-center gap-2.5 rounded-[7px] px-3 py-2.5 text-left text-xs text-sidebar-foreground";

const sectionItem = cn(
  navItem,
  "transition-colors duration-200 ease-[ease] motion-reduce:transition-none",
  "not-aria-[current=page]:hover:bg-card",
  "aria-[current=page]:bg-sidebar-accent aria-[current=page]:font-semibold aria-[current=page]:text-sidebar-accent-foreground",
);

const projectItem = cn(
  navItem,
  "group/project transition-[background-color,color] duration-200 ease-[ease] motion-reduce:transition-none",
  "hover:bg-(--project-color) hover:text-white",
  "focus-visible:bg-(--project-color) focus-visible:text-white",
  "aria-[current=page]:not-hover:not-focus-visible:bg-[color-mix(in_srgb,var(--project-color)_12%,var(--sidebar))]",
  "aria-[current=page]:not-hover:not-focus-visible:text-foreground",
);

const projectDot = cn(
  "size-[7px] shrink-0 rounded-[3px] bg-(--project-color)",
  "transition-[background-color,transform] duration-200 ease-[ease] motion-reduce:transition-none",
  "group-hover/project:bg-white group-hover/project:[transform:scale(1.15)]",
  "group-focus-visible/project:bg-white group-focus-visible/project:[transform:scale(1.15)]",
);

const projectCount = cn(
  "ml-auto inline-flex h-[21px] min-w-[23px] shrink-0 items-center justify-center rounded-[6px] px-[6px]",
  "text-[10px] font-semibold tabular-nums text-foreground",
  "bg-[color-mix(in_srgb,var(--project-color)_14%,transparent)]",
  "transition-[background-color,color] duration-200 ease-[ease] motion-reduce:transition-none",
  "group-hover/project:bg-white/15 group-hover/project:text-white",
  "group-focus-visible/project:bg-white/15 group-focus-visible/project:text-white",
);

function casesLabel(total: number): string {
  const form = casePlural.select(total);
  if (form === "one") return "sprawa";
  if (form === "few") return "sprawy";
  return "spraw";
}

function badgeText(total: number): string {
  return total > BADGE_CAP ? `${BADGE_CAP}+` : String(total);
}

function SectionLink({
  to,
  icon: Icon,
  active,
  onNavigate,
  children,
}: {
  to: string;
  icon: LucideIcon;
  active: boolean;
  onNavigate?: () => void;
  children: ReactNode;
}) {
  return (
    <Link
      to={to}
      aria-current={active ? "page" : undefined}
      onClick={onNavigate}
      className={sectionItem}
    >
      <Icon aria-hidden className="size-[18px]" strokeWidth={1.6} />
      {children}
    </Link>
  );
}

function ProjectLink({
  project,
  total,
  active,
  onNavigate,
}: {
  project: Project;
  total: number | undefined;
  active: boolean;
  onNavigate?: () => void;
}) {
  const name = project.display_name || project.slug;
  const style = { "--project-color": `var(--project-${project.ui_color})` } as CSSProperties;
  // One label: a name joined from flex items gets a space before the comma.
  const label = total === undefined ? undefined : `${name}, ${total} ${casesLabel(total)}`;

  return (
    <Link
      to={`/?${new URLSearchParams({ project: project.slug })}`}
      aria-current={active ? "page" : undefined}
      aria-label={label}
      onClick={onNavigate}
      style={style}
      className={projectItem}
    >
      <span data-slot="project-dot" aria-hidden className={projectDot} />
      <span className="truncate">{name}</span>
      {total === undefined ? null : (
        <span data-slot="project-count" aria-hidden className={projectCount}>
          {badgeText(total)}
        </span>
      )}
    </Link>
  );
}

function ProjectList({
  selected,
  onNavigate,
}: {
  selected: string | null;
  onNavigate?: () => void;
}) {
  const projects = useProjects();
  const cases = useCases(TOTALS_FILTERS);
  const totals = cases.data?.pages[0]?.project_counts;
  const totalFor = (id: string) =>
    totals ? (totals.find((entry) => entry.project_id === id)?.total ?? 0) : undefined;

  if (projects.isPending) return null;
  if (projects.isError) {
    return <li className="px-3 py-2.5 text-xs text-destructive">Nie udało się wczytać projektów</li>;
  }
  if (projects.data.length === 0) {
    return <li className="px-3 py-2.5 text-xs text-sidebar-foreground">Brak projektów</li>;
  }

  return projects.data.map((project) => (
    <li key={project.id}>
      <ProjectLink
        project={project}
        total={totalFor(project.id)}
        active={selected === project.slug}
        onNavigate={onNavigate}
      />
    </li>
  ));
}

function ConnectionState() {
  const { status } = useDashboardConnection();

  return (
    <div role="status" className="flex items-center gap-2 text-[10px] text-sidebar-foreground">
      <span aria-hidden className={cn("size-1.5 shrink-0 rounded-full", connectionDots[status])} />
      {connectionLabels[status]}
    </div>
  );
}

interface SidebarProps {
  className?: string;
  /** Called after a destination is chosen, e.g. to close the mobile menu. */
  onNavigate?: () => void;
}

export function Sidebar({ className, onNavigate }: SidebarProps) {
  const { pathname, search } = useLocation();
  const selectedProject = pathname === "/" ? new URLSearchParams(search).get("project") : null;
  const decisions = useCases(TOTALS_FILTERS).data?.pages[0]?.counts.decision ?? 0;

  return (
    <aside
      className={cn(
        "flex flex-col gap-[26px] border-sidebar-border bg-sidebar px-4 pt-[27px] pb-4 text-sidebar-foreground",
        className,
      )}
    >
      <Link
        to="/"
        aria-label="Harmony"
        onClick={onNavigate}
        className="flex items-center gap-2.5 self-start rounded-[7px] pl-2.5 text-[22px] leading-none font-bold tracking-[-0.7px] text-foreground"
      >
        <span aria-hidden className="flex -rotate-12 items-center gap-[3px]">
          <span className="h-[23px] w-[5px] rounded bg-primary" />
          <span className="h-8 w-[5px] rounded bg-primary" />
          <span className="h-[19px] w-[5px] rounded bg-primary" />
        </span>
        harmony
        <span className="-ml-1.5 self-end pb-0.5 text-[10px] font-normal tracking-normal text-sidebar-foreground">
          workspace
        </span>
      </Link>

      <nav aria-label="Główna" className="grid gap-1">
        <SectionLink to="/" icon={Inbox} active={pathname === "/"} onNavigate={onNavigate}>
          Centrum spraw
          {decisions > 0 ? (
            <>
              <span
                aria-hidden
                className="ml-auto rounded-[4px] bg-primary px-[5px] py-px text-[10px] font-normal text-primary-foreground"
              >
                {decisions}
              </span>
              <span className="sr-only">{`, ${decisions} do decyzji`}</span>
            </>
          ) : null}
        </SectionLink>
        <SectionLink
          to="/automations"
          icon={Zap}
          active={pathname.startsWith("/automations")}
          onNavigate={onNavigate}
        >
          Automatyzacje
        </SectionLink>
        <SectionLink
          to="/integrations"
          icon={Link2}
          active={pathname.startsWith("/integrations")}
          onNavigate={onNavigate}
        >
          Integracje
        </SectionLink>
      </nav>

      <div>
        <h2 className="px-3 pt-[5px] pb-2.5 text-[10px] font-normal tracking-[1px] text-sidebar-foreground uppercase">
          Projekty
        </h2>
        <nav aria-label="Projekty">
          <ul className="grid gap-1">
            <ProjectList selected={selectedProject} onNavigate={onNavigate} />
            <li>
              <SectionLink
                to="/projects"
                icon={LayoutGrid}
                active={pathname === "/projects"}
                onNavigate={onNavigate}
              >
                Wszystkie projekty
              </SectionLink>
            </li>
          </ul>
        </nav>
      </div>

      <div className="mt-auto grid gap-1 pt-10">
        <SectionLink
          to="/overview"
          icon={Activity}
          active={pathname === "/overview" || pathname === "/runtime"}
          onNavigate={onNavigate}
        >
          Diagnostyka
        </SectionLink>
        <div className="mt-2 grid gap-2 border-t border-sidebar-border px-2.5 pt-[15px]">
          <ConnectionState />
          <div className="flex items-center justify-between gap-2 text-xs text-foreground">
            <span>Przestrzeń zespołu</span>
            <ThemeToggle />
          </div>
        </div>
      </div>
    </aside>
  );
}
