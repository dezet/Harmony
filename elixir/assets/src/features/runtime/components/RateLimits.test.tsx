import { render, screen } from "@testing-library/react";
import { describe, it, expect } from "vitest";
import { RateLimits } from "@/features/runtime/components/RateLimits";

describe("RateLimits", () => {
  it("renders the empty message for null", () => {
    render(<RateLimits value={null} />);
    expect(screen.getByText(/no rate limit data/i)).toBeInTheDocument();
  });

  it("renders the empty message for undefined", () => {
    render(<RateLimits value={undefined} />);
    expect(screen.getByText(/no rate limit data/i)).toBeInTheDocument();
  });

  it("renders the empty message for an empty object", () => {
    render(<RateLimits value={{}} />);
    expect(screen.getByText(/no rate limit data/i)).toBeInTheDocument();
  });

  it("renders key-value fallback for stub shape {remaining: 42} without crashing", () => {
    render(<RateLimits value={{ remaining: 42 }} />);
    expect(screen.getByText("remaining")).toBeInTheDocument();
    expect(screen.getByText("42")).toBeInTheDocument();
    // Should not render a progress bar
    expect(screen.queryByRole("progressbar")).not.toBeInTheDocument();
  });

  it("renders progress bars with correct aria attributes for a full payload", () => {
    render(
      <RateLimits
        value={{
          limit_id: "default",
          primary: { used: 1200, limit: 5000, reset_in_ms: 3600000 },
          secondary: { used: 30, limit: 100 },
        }}
      />,
    );

    // Header
    expect(screen.getByText("default")).toBeInTheDocument();

    // Primary progress bar
    const primaryBar = screen.getByRole("progressbar", { name: "primary usage" });
    expect(primaryBar).toBeInTheDocument();
    expect(primaryBar).toHaveAttribute("aria-valuenow", "1200");
    expect(primaryBar).toHaveAttribute("aria-valuemin", "0");
    expect(primaryBar).toHaveAttribute("aria-valuemax", "5000");

    // used / limit text for primary
    expect(screen.getByText("1200 / 5000")).toBeInTheDocument();

    // Secondary progress bar
    const secondaryBar = screen.getByRole("progressbar", { name: "secondary usage" });
    expect(secondaryBar).toBeInTheDocument();
    expect(secondaryBar).toHaveAttribute("aria-valuenow", "30");
    expect(secondaryBar).toHaveAttribute("aria-valuemax", "100");

    // used / limit text for secondary
    expect(screen.getByText("30 / 100")).toBeInTheDocument();
  });

  it("shows reset countdown when reset_in_ms is present", () => {
    render(
      <RateLimits
        value={{
          primary: { used: 10, limit: 100, reset_in_ms: 3600000 },
        }}
      />,
    );
    expect(screen.getByText(/resets in/i)).toBeInTheDocument();
  });

  it("shows limit_name header when present (preferred over limit_id)", () => {
    render(
      <RateLimits
        value={{
          limit_id: "raw-id",
          limit_name: "Human Friendly Name",
          primary: { used: 1, limit: 10 },
        }}
      />,
    );
    expect(screen.getByText("Human Friendly Name")).toBeInTheDocument();
    expect(screen.queryByText("raw-id")).not.toBeInTheDocument();
  });

  it("renders key-value rows for a bucket with no used/limit", () => {
    render(
      <RateLimits
        value={{
          credits: { quota: "50000", tier: "pro" },
        }}
      />,
    );
    expect(screen.queryByRole("progressbar")).not.toBeInTheDocument();
    expect(screen.getByText("quota")).toBeInTheDocument();
    expect(screen.getByText("50000")).toBeInTheDocument();
  });
});
