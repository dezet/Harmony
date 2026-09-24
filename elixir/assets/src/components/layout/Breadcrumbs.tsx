/* eslint-disable react-refresh/only-export-components */
import { Fragment } from "react";
import { Link, useLocation } from "react-router-dom";

export interface Crumb {
  label: string;
  /** Absent for a plain label such as the team space. */
  to?: string;
}

const TEAM_SPACE: Crumb = { label: "Przestrzeń zespołu" };
const DIAGNOSTICS: Crumb = { label: "Diagnostyka", to: "/overview" };

// Static path→label mapping of layout A; identifiers stay as they are in the URL.
export function crumbsFor(pathname: string): Crumb[] {
  const [first, second, third, fourth, fifth] = pathname.split("/").filter(Boolean);

  if (!first) return [TEAM_SPACE, { label: "Centrum spraw", to: "/" }];
  if (first === "cases" && second && !third) {
    return [TEAM_SPACE, { label: "Centrum spraw", to: "/" }, { label: "Szczegóły sprawy", to: pathname }];
  }
  if (first === "automations" && !third) {
    const crumbs: Crumb[] = [TEAM_SPACE, { label: "Automatyzacje", to: "/automations" }];
    if (second) crumbs.push({ label: second === "new" ? "Nowa reguła" : "Reguła", to: pathname });
    return crumbs;
  }
  if (first === "integrations" && !second) {
    return [TEAM_SPACE, { label: "Integracje", to: "/integrations" }];
  }
  if (first === "overview" && !second) return [TEAM_SPACE, DIAGNOSTICS];
  if (first === "runtime" && !second) {
    return [TEAM_SPACE, DIAGNOSTICS, { label: "Środowisko uruchomieniowe", to: "/runtime" }];
  }
  if (first === "projects") {
    const crumbs: Crumb[] = [TEAM_SPACE, { label: "Projekty", to: "/projects" }];
    if (second === "new" && !third) crumbs.push({ label: "Nowy projekt", to: "/projects/new" });
    else if (second && third === "edit" && !fourth) crumbs.push({ label: "Edycja", to: pathname });
    else if (second && third === "runs" && fourth && !fifth) {
      crumbs.push({ label: second, to: `/projects/${second}` });
      crumbs.push({ label: fourth, to: pathname });
    } else if (second && !third) crumbs.push({ label: second, to: `/projects/${second}` });
    return crumbs;
  }
  return [TEAM_SPACE, { label: "Nie znaleziono", to: pathname }];
}

export function Breadcrumbs() {
  const { pathname } = useLocation();
  const crumbs = crumbsFor(pathname);

  return (
    <nav aria-label="Ścieżka" className="flex min-w-0 items-center gap-1.5 text-[11px] text-muted-foreground min-[851px]:gap-2.5">
      {crumbs.map((crumb, i) => {
        const last = i === crumbs.length - 1;
        return (
          <Fragment key={`${i}-${crumb.label}`}>
            {i > 0 ? <span aria-hidden>/</span> : null}
            {last ? (
              <span aria-current="page" className="truncate text-foreground">
                {crumb.label}
              </span>
            ) : crumb.to ? (
              <Link to={crumb.to} className="truncate hover:text-foreground">
                {crumb.label}
              </Link>
            ) : (
              <span className="truncate">{crumb.label}</span>
            )}
          </Fragment>
        );
      })}
    </nav>
  );
}
