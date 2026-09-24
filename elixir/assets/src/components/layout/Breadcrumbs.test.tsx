import { render, screen } from "@testing-library/react";
import { MemoryRouter } from "react-router-dom";
import { describe, it, expect } from "vitest";
import { Breadcrumbs, crumbsFor } from "@/components/layout/Breadcrumbs";

const labels = (pathname: string) => crumbsFor(pathname).map((c) => c.label);

describe("crumbsFor", () => {
  it("starts every trail at the team space and names the A sections in Polish", () => {
    expect(labels("/")).toEqual(["Przestrzeń zespołu", "Centrum spraw"]);
    expect(labels("/automations")).toEqual(["Przestrzeń zespołu", "Automatyzacje"]);
    expect(labels("/integrations")).toEqual(["Przestrzeń zespołu", "Integracje"]);
    expect(labels("/overview")).toEqual(["Przestrzeń zespołu", "Diagnostyka"]);
    expect(labels("/runtime")).toEqual([
      "Przestrzeń zespołu",
      "Diagnostyka",
      "Środowisko uruchomieniowe",
    ]);
    expect(crumbsFor("/runtime").find((c) => c.label === "Diagnostyka")?.to).toBe("/overview");
    expect(crumbsFor("/")[0].to).toBeUndefined();
  });

  it("names the standalone case detail under the Case Center", () => {
    expect(labels("/cases/jira_1")).toEqual(["Przestrzeń zespołu", "Centrum spraw", "Szczegóły sprawy"]);
    expect(crumbsFor("/cases/jira_1").find((c) => c.label === "Centrum spraw")?.to).toBe("/");
  });

  it("keeps project and run deep-link trails", () => {
    expect(labels("/projects")).toEqual(["Przestrzeń zespołu", "Projekty"]);
    expect(labels("/projects/new")).toEqual(["Przestrzeń zespołu", "Projekty", "Nowy projekt"]);
    expect(labels("/projects/p1/edit")).toEqual(["Przestrzeń zespołu", "Projekty", "Edycja"]);
    expect(labels("/projects/alpha")).toEqual(["Przestrzeń zespołu", "Projekty", "alpha"]);
    expect(crumbsFor("/projects/alpha").find((c) => c.label === "alpha")?.to).toBe(
      "/projects/alpha",
    );
    expect(labels("/projects/alpha/runs/COD-10")).toEqual([
      "Przestrzeń zespołu",
      "Projekty",
      "alpha",
      "COD-10",
    ]);
    expect(crumbsFor("/projects/alpha/runs/COD-10").find((c) => c.label === "alpha")?.to).toBe(
      "/projects/alpha",
    );
    expect(crumbsFor("/projects/alpha/runs/COD-10").find((c) => c.label === "COD-10")?.to).toBe(
      "/projects/alpha/runs/COD-10",
    );
  });

  it("names unknown paths as not found", () => {
    expect(labels("/nope")).toEqual(["Przestrzeń zespołu", "Nie znaleziono"]);
  });
});

describe("Breadcrumbs", () => {
  it("renders the trail with the current page unlinked", () => {
    render(
      <MemoryRouter initialEntries={["/projects/new"]}>
        <Breadcrumbs />
      </MemoryRouter>,
    );
    const nav = screen.getByRole("navigation", { name: "Ścieżka" });
    expect(nav).toBeInTheDocument();
    expect(screen.getByRole("link", { name: "Projekty" })).toHaveAttribute("href", "/projects");
    expect(screen.queryByRole("link", { name: "Przestrzeń zespołu" })).not.toBeInTheDocument();
    expect(screen.queryByRole("link", { name: "Nowy projekt" })).not.toBeInTheDocument();
    expect(screen.getByText("Nowy projekt")).toHaveAttribute("aria-current", "page");
  });
});
