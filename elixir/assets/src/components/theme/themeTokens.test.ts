import { describe, it, expect } from "vitest";
import css from "@/index.css?raw";

// Theme contract of layout A (spec §4.1–4.2). jsdom does not evaluate Tailwind,
// so the token values are read from the stylesheet itself.

function block(selector: string): string {
  const start = css.indexOf(`${selector} {`);
  expect(start, `${selector} block`).toBeGreaterThanOrEqual(0);
  return css.slice(start, css.indexOf("\n}", start));
}

function token(scope: string, name: string): string | undefined {
  const match = block(scope).match(new RegExp(`${name}:\\s*([^;]+);`));
  return match?.[1].trim();
}

describe("layout A theme tokens", () => {
  it("maps the light palette of A onto the shadcn tokens", () => {
    expect(token(":root", "--background")).toBe("#f8f9fb");
    expect(token(":root", "--card")).toBe("#ffffff");
    expect(token(":root", "--popover")).toBe("#ffffff");
    expect(token(":root", "--sidebar")).toBe("#f3f4f7");
    expect(token(":root", "--muted")).toBe("#f3f4f7");
    expect(token(":root", "--foreground")).toBe("#20242f");
    expect(token(":root", "--muted-foreground")).toBe("#687183");
    expect(token(":root", "--border")).toBe("#e6e8ee");
    expect(token(":root", "--primary")).toBe("#6052d5");
    expect(token(":root", "--ring")).toBe("#6052d5");
    expect(token(":root", "--accent")).toBe("#efedfc");
    expect(token(":root", "--success")).toBe("#237655");
    expect(token(":root", "--success-surface")).toBe("#eaf5ee");
    expect(token(":root", "--warning")).toBe("#936018");
    expect(token(":root", "--warning-surface")).toBe("#fcf3df");
    expect(token(":root", "--destructive")).toBe("#b74551");
    expect(token(":root", "--destructive-surface")).toBe("#fcecee");
  });

  it("defines the three project identity colors", () => {
    expect(token(":root", "--project-purple")).toBe("#7866b5");
    expect(token(":root", "--project-gold")).toBe("#966d24");
    expect(token(":root", "--project-teal")).toBe("#397e6b");
  });

  it("uses the A font stack without an external or bundled web font", () => {
    expect(css).toMatch(/--font-sans:\s*Inter, "Segoe UI", Arial, sans-serif;/);
    expect(css).not.toMatch(/geist/i);
    expect(css).not.toMatch(/fonts\.googleapis|@font-face/);
  });

  it("sets the 14 px base and the 29 px / 650 / 1.2 page title", () => {
    expect(css).toMatch(/font-size:\s*14px;/);
    expect(css).toMatch(/--text-title:\s*29px;/);
    expect(css).toMatch(/--text-title--line-height:\s*1\.2;/);
    expect(css).toMatch(/--text-title--font-weight:\s*650;/);
  });

  it("keeps a visible focus ring and removes motion for reduced-motion users", () => {
    expect(css).toMatch(/:focus-visible\s*{[^}]*outline:\s*3px solid var\(--ring\)/);
    expect(css).toMatch(
      /@media \(prefers-reduced-motion: reduce\)\s*{[^}]*\*,[\s\S]*?transition: none !important;[\s\S]*?animation: none !important;/,
    );
  });

  it("dark mode keeps the purple accent and the project colors of A", () => {
    const dark = block(".dark");
    expect(token(".dark", "--primary")).toBe("#6052d5");
    expect(dark).toMatch(/--ring:\s*#[0-9a-f]{6};/);
    expect(dark).not.toMatch(/--project-/);
    expect(css).not.toMatch(/data-concept/);
  });
});
