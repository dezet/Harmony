import { render, screen } from "@testing-library/react";
import { afterEach, describe, expect, it, vi } from "vitest";
import { ErrorBoundary } from "@/components/ErrorBoundary";

function Thrower(): never {
  throw new Error("Widok się rozpadł");
}

afterEach(() => vi.restoreAllMocks());

describe("ErrorBoundary", () => {
  it("renders its children when nothing fails", () => {
    render(
      <ErrorBoundary>
        <p>Treść</p>
      </ErrorBoundary>,
    );
    expect(screen.getByText("Treść")).toBeInTheDocument();
  });

  it("shows a Polish recovery screen instead of a white page, without a stack trace", () => {
    vi.spyOn(console, "error").mockImplementation(() => undefined);
    render(
      <ErrorBoundary>
        <Thrower />
      </ErrorBoundary>,
    );

    expect(screen.getByRole("heading", { level: 1, name: "Coś poszło nie tak" })).toBeInTheDocument();
    expect(screen.getByRole("alert")).toHaveTextContent(/Odśwież stronę/);
    expect(screen.getByRole("link", { name: "Wróć do Centrum spraw" })).toHaveAttribute("href", "/");
    expect(screen.getByText(/Widok się rozpadł/)).toBeInTheDocument();
    expect(document.body).not.toHaveTextContent(/at Thrower|\.tsx:\d+/);
  });
});
