import { Activity, LayoutDashboard, Plus } from "lucide-react";
import { Link, NavLink } from "react-router-dom";
import { ThemeToggle } from "@/components/theme/ThemeToggle";
import { ConnectionStatus } from "@/features/dashboard/components/ConnectionStatus";
import { useDashboard } from "@/features/dashboard/useDashboard";
import { projectHealth, type ProjectHealth } from "@/lib/health";
import { cn } from "@/lib/utils";

const healthDot: Record<ProjectHealth, string> = {
  healthy: "bg-emerald-500",
  retrying: "bg-amber-500",
  blocked: "bg-red-500",
  idle: "bg-muted-foreground/40",
};

function navLinkClass({ isActive }: { isActive: boolean }) {
  return cn(
    "flex items-center gap-2 rounded-md px-2 py-1.5 text-sm",
    isActive
      ? "bg-sidebar-accent font-medium text-sidebar-accent-foreground"
      : "hover:bg-sidebar-accent/50",
  );
}

export function Sidebar() {
  const { data } = useDashboard();
  const projects = data?.projects ?? [];

  return (
    <aside className="flex w-60 shrink-0 flex-col border-r bg-sidebar text-sidebar-foreground">
      <div className="px-4 py-4 text-base font-semibold">
        <Link to="/">Harmony</Link>
      </div>

      <nav aria-label="Main" className="flex-1 space-y-6 overflow-y-auto px-2">
        <div className="space-y-1">
          <NavLink to="/" end className={navLinkClass}>
            <LayoutDashboard className="size-4" /> Overview
          </NavLink>
          <NavLink to="/runtime" className={navLinkClass}>
            <Activity className="size-4" /> Runtime
          </NavLink>
        </div>

        <div>
          <div className="flex items-center justify-between px-2 pb-1">
            <NavLink
              to="/projects"
              end
              className="text-xs font-medium uppercase tracking-wide text-muted-foreground hover:text-foreground"
            >
              Projects
            </NavLink>
            <Link
              to="/projects/new"
              aria-label="Create project"
              className="text-muted-foreground hover:text-foreground"
            >
              <Plus className="size-4" />
            </Link>
          </div>
          <ul className="space-y-1">
            {projects.map((p, i) => {
              const health = projectHealth(p.counts);
              const active = p.counts.running + p.counts.retrying + p.counts.blocked;
              return (
                <li key={p.id ?? p.slug ?? p.name ?? String(i)}>
                  {/* Phase 1 transitional target; Phase 2 repoints to /projects/:slug */}
                  <Link
                    to={p.id ? `/projects/${p.id}/edit` : "/projects"}
                    className="flex items-center gap-2 rounded-md px-2 py-1.5 text-sm hover:bg-sidebar-accent/50"
                  >
                    <span aria-hidden className={cn("size-2 rounded-full", healthDot[health])} />
                    <span className="truncate">{p.slug ?? p.name ?? "unnamed"}</span>
                    <span className="sr-only">({health})</span>
                    {active > 0 ? (
                      <span className="ml-auto font-mono text-xs text-muted-foreground">
                        {active}
                      </span>
                    ) : null}
                  </Link>
                </li>
              );
            })}
            {projects.length === 0 ? (
              <li className="px-2 py-1.5 text-sm text-muted-foreground">No projects yet</li>
            ) : null}
          </ul>
        </div>
      </nav>

      <div className="flex items-center justify-between border-t px-4 py-3">
        <ConnectionStatus />
        <ThemeToggle />
      </div>
    </aside>
  );
}
