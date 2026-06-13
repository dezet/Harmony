import { render, screen } from "@testing-library/react";
import { MemoryRouter } from "react-router-dom";
import { describe, it, expect } from "vitest";
import { Breadcrumbs, crumbsFor } from "@/components/layout/Breadcrumbs";

describe("crumbsFor", () => {
  it("maps known paths to crumb trails", () => {
    expect(crumbsFor("/")).toEqual([{ label: "Overview", to: "/" }]);
    expect(crumbsFor("/runtime").map((c) => c.label)).toEqual(["Overview", "Runtime"]);
    expect(crumbsFor("/projects").map((c) => c.label)).toEqual(["Overview", "Projects"]);
    expect(crumbsFor("/projects/new").map((c) => c.label)).toEqual([
      "Overview",
      "Projects",
      "New",
    ]);
    expect(crumbsFor("/projects/p1/edit").map((c) => c.label)).toEqual([
      "Overview",
      "Projects",
      "Edit",
    ]);
    expect(crumbsFor("/projects/alpha").map((c) => c.label)).toEqual([
      "Overview",
      "Projects",
      "alpha",
    ]);
    expect(crumbsFor("/projects/alpha").find((c) => c.label === "alpha")?.to).toBe(
      "/projects/alpha",
    );
    expect(crumbsFor("/projects/alpha/runs/COD-10").map((c) => c.label)).toEqual([
      "Overview",
      "Projects",
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
});

describe("Breadcrumbs", () => {
  it("renders the trail with the current page unlinked", () => {
    render(
      <MemoryRouter initialEntries={["/projects/new"]}>
        <Breadcrumbs />
      </MemoryRouter>,
    );
    const nav = screen.getByRole("navigation", { name: "Breadcrumb" });
    expect(nav).toBeInTheDocument();
    expect(screen.getByRole("link", { name: "Projects" })).toHaveAttribute("href", "/projects");
    // current crumb is text, not a link
    expect(screen.queryByRole("link", { name: "New" })).not.toBeInTheDocument();
    expect(screen.getByText("New")).toHaveAttribute("aria-current", "page");
  });
});
