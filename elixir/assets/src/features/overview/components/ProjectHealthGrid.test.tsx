import { render, screen } from "@testing-library/react";
import { MemoryRouter } from "react-router-dom";
import { describe, it, expect } from "vitest";
import { ProjectHealthGrid } from "@/features/overview/components/ProjectHealthGrid";

describe("ProjectHealthGrid", () => {
  it("renders a card per project with counts", () => {
    render(
      <MemoryRouter>
        <ProjectHealthGrid
          projects={[
            {
              id: "p1",
              slug: "alpha",
              name: "Alpha",
              counts: { running: 2, retrying: 1, blocked: 0 },
            },
          ]}
        />
      </MemoryRouter>,
    );
    expect(screen.getByText("alpha")).toBeInTheDocument();
    expect(screen.getByText("2 running")).toBeInTheDocument();
    expect(screen.getByText("1 retrying")).toBeInTheDocument();
    expect(screen.getByText("0 blocked")).toBeInTheDocument();
  });

  it("offers creating the first project when the list is empty", () => {
    render(
      <MemoryRouter>
        <ProjectHealthGrid projects={[]} />
      </MemoryRouter>,
    );
    expect(screen.getByRole("link", { name: /create the first one/i })).toHaveAttribute(
      "href",
      "/projects/new",
    );
  });
});
