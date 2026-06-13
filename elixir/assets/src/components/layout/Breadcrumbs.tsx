/* eslint-disable react-refresh/only-export-components */
import { Fragment } from "react";
import { Link, useLocation } from "react-router-dom";

export interface Crumb {
  label: string;
  to: string;
}

// Static path→label mapping. Phase 2+ extends this with project/run names
// once routes carry slugs worth displaying.
export function crumbsFor(pathname: string): Crumb[] {
  const crumbs: Crumb[] = [{ label: "Overview", to: "/" }];
  if (pathname === "/") return crumbs;

  const [first, second, third, fourth, fifth] = pathname.split("/").filter(Boolean);
  if (first === "runtime") return [...crumbs, { label: "Runtime", to: "/runtime" }];
  if (first === "projects") {
    crumbs.push({ label: "Projects", to: "/projects" });
    if (second === "new") crumbs.push({ label: "New", to: "/projects/new" });
    else if (second && third === "edit") crumbs.push({ label: "Edit", to: pathname });
    else if (second && third === "runs" && fourth && !fifth) {
      crumbs.push({ label: second, to: `/projects/${second}` });
      crumbs.push({ label: fourth, to: pathname });
    } else if (second && !third) crumbs.push({ label: second, to: `/projects/${second}` });
    return crumbs;
  }
  return [...crumbs, { label: "Not found", to: pathname }];
}

export function Breadcrumbs() {
  const { pathname } = useLocation();
  const crumbs = crumbsFor(pathname);

  return (
    <nav aria-label="Breadcrumb" className="flex items-center gap-1.5 text-sm text-muted-foreground">
      {crumbs.map((crumb, i) => {
        const last = i === crumbs.length - 1;
        return (
          <Fragment key={crumb.to}>
            {i > 0 ? <span aria-hidden>/</span> : null}
            {last ? (
              <span aria-current="page" className="text-foreground">
                {crumb.label}
              </span>
            ) : (
              <Link to={crumb.to} className="hover:text-foreground">
                {crumb.label}
              </Link>
            )}
          </Fragment>
        );
      })}
    </nav>
  );
}
