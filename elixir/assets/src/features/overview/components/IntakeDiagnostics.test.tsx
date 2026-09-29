import { render, screen, within } from "@testing-library/react";
import { MemoryRouter } from "react-router-dom";
import { describe, expect, it } from "vitest";
import { IntakeDiagnostics } from "@/features/overview/components/IntakeDiagnostics";
import fixture from "@/test/fixtures/intake_diagnostics.fixture.json";
import type { IntakeDiagnostics as IntakeDiagnosticsPayload } from "@/types/contract";

const payload = fixture as IntakeDiagnosticsPayload;

function renderPanel(value: IntakeDiagnosticsPayload | undefined) {
  render(
    <MemoryRouter>
      <IntakeDiagnostics value={value} />
    </MemoryRouter>,
  );
  return within(screen.getByRole("region", { name: "Intake Jira" }));
}

describe("IntakeDiagnostics (spec §12)", () => {
  it("shows the runtime switches as text, not only as color", () => {
    const panel = renderPanel(payload);
    const switches = within(panel.getByRole("list", { name: "Przełączniki intake" }));
    expect(switches.getByText("Intake: włączony")).toBeInTheDocument();
    expect(switches.getByText("Efekty zewnętrzne: wyłączone")).toBeInTheDocument();
    expect(switches.getByText("Analiza: włączona")).toBeInTheDocument();
  });

  it("shows backlog, oldest waiting effect, unknown results, stale leases and the analysis pool", () => {
    const panel = renderPanel(payload);
    const group = (name: string) => panel.getByRole("group", { name });
    const metric = (name: string) => within(group(name));

    expect(metric("Zaległe efekty").getByText("4")).toBeInTheDocument();
    expect(metric("Najstarszy oczekujący").getByText(/\d/)).toBeInTheDocument();
    expect(metric("Nieznany wynik").getByText("1")).toBeInTheDocument();
    expect(metric("Wygasłe dzierżawy").getByText("2")).toBeInTheDocument();
    expect(group("Wygasłe dzierżawy")).toHaveTextContent(/efekty: 1 · reguły: 1/);
    expect(metric("Pula analizy").getByText("1 / 1")).toBeInTheDocument();
    expect(group("Pula analizy")).toHaveTextContent(/w kolejce: 1/);
  });

  it("warns that an unknown result must be checked with the provider before a retry", () => {
    const panel = renderPanel(payload);
    expect(panel.getByRole("status")).toHaveTextContent(/sprawdź u dostawcy/i);
  });

  it("lists the queue of every operation with Polish names", () => {
    const panel = renderPanel(payload);
    const table = within(panel.getByRole("table", { name: "Kolejki efektów" }));
    for (const name of ["Utworzenie w Linear", "Analiza", "Komentarz Jira", "E-mail", "SMS"]) {
      expect(table.getByRole("rowheader", { name })).toBeInTheDocument();
    }
    const email = table.getByRole("row", { name: /E-mail/ });
    expect(within(email).getAllByRole("cell").map((cell) => cell.textContent)).toEqual(["1", "0", "1", "1", "1", "0"]);
  });

  it("lists channel errors by safe code and count", () => {
    const panel = renderPanel(payload);
    const errors = within(panel.getByRole("list", { name: "Błędy kanałów" }));
    expect(errors.getByText("smtp_timeout")).toBeInTheDocument();
    expect(errors.getAllByRole("listitem")[0]).toHaveTextContent(/E-mail.*smtp_timeout.*1/);
  });

  it("shows each rule's last success and scan time, and a rule that never ran", () => {
    const panel = renderPanel(payload);
    const rules = within(panel.getByRole("table", { name: "Reguły Jira" }));
    const active = rules.getByRole("row", { name: /Pilne zgłoszenia/ });
    expect(active).toHaveTextContent("Finanse");
    expect(active).toHaveTextContent("2,5 s");
    expect(active).toHaveTextContent("jira_unavailable");
    expect(rules.getByRole("link", { name: "Pilne zgłoszenia" })).toHaveAttribute(
      "href",
      "/automations/11111111-1111-4111-8111-111111111111",
    );
    const idle = rules.getByRole("row", { name: /Zapasowa reguła/ });
    expect(idle).toHaveTextContent("Nigdy");
  });

  it("says so when there are no errors or rules", () => {
    const panel = renderPanel({ ...payload, channel_errors: [], rules: [], unknown: 0 });
    expect(panel.getByText("Brak błędów kanałów.")).toBeInTheDocument();
    expect(panel.getByText("Brak reguł Jira.")).toBeInTheDocument();
    expect(panel.queryByRole("status")).not.toBeInTheDocument();
  });

  it("reports missing diagnostics instead of zeros", () => {
    const panel = renderPanel(undefined);
    expect(panel.getByText(/Dane diagnostyczne intake są niedostępne/)).toBeInTheDocument();
    expect(panel.queryByRole("table")).not.toBeInTheDocument();
  });
});
