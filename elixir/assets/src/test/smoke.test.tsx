import { render, screen } from "@testing-library/react";
import { describe, it, expect } from "vitest";

function Hello() {
  return <h1>Harmony</h1>;
}

describe("vitest harness", () => {
  it("renders a component", () => {
    render(<Hello />);
    expect(screen.getByRole("heading", { name: "Harmony" })).toBeInTheDocument();
  });
});
