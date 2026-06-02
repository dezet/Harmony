import { render, screen } from "@testing-library/react";
import { MemoryRouter } from "react-router-dom";
import { describe, it, expect } from "vitest";
import { AppRoutes } from "@/App";

function renderAt(path: string) {
  return render(
    <MemoryRouter initialEntries={[path]}>
      <AppRoutes />
    </MemoryRouter>,
  );
}

describe("AppRoutes", () => {
  it("shows the nav and the dashboard at /", () => {
    renderAt("/");
    expect(screen.getByRole("navigation")).toBeInTheDocument();
    expect(screen.getByRole("heading", { name: /dashboard/i })).toBeInTheDocument();
  });

  it("shows the projects page at /projects", () => {
    renderAt("/projects");
    expect(screen.getByRole("heading", { name: /projects/i })).toBeInTheDocument();
  });

  it("shows a not-found page for unknown routes", () => {
    renderAt("/nope");
    expect(screen.getByText(/not found/i)).toBeInTheDocument();
  });
});
