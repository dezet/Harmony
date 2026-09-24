import { render, screen } from "@testing-library/react";
import { describe, it, expect } from "vitest";
import { StatusBadge } from "@/components/StatusBadge";

describe("StatusBadge", () => {
  it.each([
    ["queued", "W kolejce"],
    ["running", "W toku"],
    ["retrying", "Ponawianie"],
    ["blocked", "Zablokowany"],
    ["failed", "Nieudany"],
    ["stopped", "Zatrzymany"],
    ["human_review", "Przegląd człowieka"],
    ["completed", "Zakończony"],
    ["succeeded", "Zakończony sukcesem"],
    ["handed_off", "Przekazany"],
    ["cancelled", "Anulowany"],
  ])("labels the Harmony run status %s in Polish and keeps the raw value", (status, label) => {
    render(<StatusBadge status={status} />);
    const badge = screen.getByText(label);
    expect(badge).toHaveAttribute("data-slot", "badge");
    expect(badge).toHaveAttribute("title", status);
  });

  it("uses the destructive variant for failed and blocked runs", () => {
    render(
      <>
        <StatusBadge status="failed" />
        <StatusBadge status="blocked" />
      </>,
    );
    expect(screen.getByText("Nieudany")).toHaveAttribute("data-variant", "destructive");
    expect(screen.getByText("Zablokowany")).toHaveAttribute("data-variant", "destructive");
  });

  it("shows an unknown historical status verbatim instead of hiding it", () => {
    render(<StatusBadge status="someUnknownStatus" />);
    expect(screen.getByText("someUnknownStatus")).toBeInTheDocument();
  });

  it("keeps external raw data (e.g. a CI status) untranslated", () => {
    render(<StatusBadge status="running" raw />);
    expect(screen.getByText("running")).toBeInTheDocument();
    expect(screen.queryByText("W toku")).not.toBeInTheDocument();
  });
});
