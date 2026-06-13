import { render, screen } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { describe, it, expect, afterEach } from "vitest";
import { ThemeProvider } from "@/components/theme/ThemeProvider";
import { ThemeToggle } from "@/components/theme/ThemeToggle";

afterEach(() => {
  localStorage.clear();
  document.documentElement.classList.remove("dark");
});

describe("ThemeToggle", () => {
  it("toggles the dark class on <html>", async () => {
    const user = userEvent.setup();
    render(
      <ThemeProvider>
        <ThemeToggle />
      </ThemeProvider>,
    );

    const button = await screen.findByRole("button", { name: /switch to dark mode/i });
    await user.click(button);
    expect(document.documentElement.classList.contains("dark")).toBe(true);

    await user.click(screen.getByRole("button", { name: /switch to light mode/i }));
    expect(document.documentElement.classList.contains("dark")).toBe(false);
  });
});
