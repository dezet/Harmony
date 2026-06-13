import { render, screen } from "@testing-library/react";
import { describe, it, expect } from "vitest";
import { ConnectionStatus } from "@/features/dashboard/components/ConnectionStatus";
import { DashboardConnectionProvider } from "@/lib/dashboardConnection";

function renderStatus(status: "connecting" | "live" | "reconnecting" | "offline") {
  render(
    <DashboardConnectionProvider initialStatus={status}>
      <ConnectionStatus />
    </DashboardConnectionProvider>,
  );
}

describe("ConnectionStatus", () => {
  const cases = [
    ["connecting", "Connecting…"],
    ["live", "Live"],
    ["reconnecting", "Reconnecting…"],
    ["offline", "Offline"],
  ] as const;

  it.each(cases)("renders %s as %s", (status, label) => {
    renderStatus(status);
    expect(screen.getByText(label)).toBeInTheDocument();
  });
});
