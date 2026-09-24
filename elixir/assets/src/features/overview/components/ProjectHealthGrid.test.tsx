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
    expect(screen.getByText("w toku: 2")).toBeInTheDocument();
    expect(screen.getByText("ponawiane: 1")).toBeInTheDocument();
    expect(screen.getByText("zablokowane: 0")).toBeInTheDocument();
    expect(screen.getByText("(ponawia)")).toHaveClass("sr-only");
  });

  it("offers creating the first project when the list is empty", () => {
    render(
      <MemoryRouter>
        <ProjectHealthGrid projects={[]} />
      </MemoryRouter>,
    );
    expect(screen.getByRole("link", { name: "Utwórz pierwszy projekt." })).toHaveAttribute(
      "href",
      "/projects/new",
    );
  });
});
