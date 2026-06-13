import { render, screen } from "@testing-library/react";
import { describe, it, expect } from "vitest";
import { RunRail } from "@/features/run/components/RunRail";
import type { RunDetail } from "@/types/contract";
import runDetailFixture from "@/test/fixtures/run_detail.fixture.json";

// Cast fixture to RunDetail
const fixture = runDetailFixture as RunDetail;

// Variant with null tokens
const noTokensDetail: RunDetail = {
  ...fixture,
  tokens: null,
};

// Variant with current_retry_attempt set
const retryingDetail: RunDetail = {
  ...fixture,
  attempts: {
    restart_count: 1,
    current_retry_attempt: 3,
  },
};

describe("RunRail", () => {
  it("renders status badge", () => {
    render(<RunRail detail={fixture} />);
    expect(screen.getByText("running")).toBeInTheDocument();
  });

  it("renders turn_count", () => {
    render(<RunRail detail={fixture} />);
    // fixture has turn_count: 7
    expect(screen.getByText("7")).toBeInTheDocument();
  });

  it("renders last_event name", () => {
    render(<RunRail detail={fixture} />);
    // fixture has last_event: "turn_end"
    expect(screen.getByText("turn_end")).toBeInTheDocument();
  });

  it("renders token totals when tokens present", () => {
    render(<RunRail detail={fixture} />);
    // fixture tokens: input 200, output 80, total 280
    expect(screen.getByText("200")).toBeInTheDocument();
    expect(screen.getByText("80")).toBeInTheDocument();
    expect(screen.getByText("280")).toBeInTheDocument();
  });

  it("renders 'No token data.' when tokens are null", () => {
    render(<RunRail detail={noTokensDetail} />);
    expect(screen.getByText("No token data.")).toBeInTheDocument();
  });

  it("renders PR link with correct href", () => {
    render(<RunRail detail={fixture} />);
    const link = screen.getByRole("link", { name: "#42" });
    expect(link).toHaveAttribute(
      "href",
      "https://github.com/acme/portal/pull/42",
    );
    expect(link).toHaveAttribute("target", "_blank");
  });

  it("renders 'No pull requests.' when PR list is empty", () => {
    render(<RunRail detail={{ ...fixture, pull_requests: [] }} />);
    expect(screen.getByText("No pull requests.")).toBeInTheDocument();
  });

  it("renders artifact kind and path", () => {
    render(<RunRail detail={fixture} />);
    // fixture artifact: kind "screenshot", path "/artifacts/screen.png"
    expect(screen.getByText("screenshot")).toBeInTheDocument();
    expect(screen.getByText("/artifacts/screen.png")).toBeInTheDocument();
  });

  it("renders 'No artifacts.' when artifact list is empty", () => {
    render(<RunRail detail={{ ...fixture, artifacts: [] }} />);
    expect(screen.getByText("No artifacts.")).toBeInTheDocument();
  });

  it("renders workspace path in mono", () => {
    render(<RunRail detail={fixture} />);
    // fixture workspace.path: "/ws/cod-10"
    expect(screen.getByText("/ws/cod-10")).toBeInTheDocument();
  });

  it("renders '—' when workspace is null", () => {
    render(<RunRail detail={{ ...fixture, workspace: null }} />);
    expect(screen.getByText("—")).toBeInTheDocument();
  });

  it("renders 'Attempt #N' when current_retry_attempt is set", () => {
    render(<RunRail detail={retryingDetail} />);
    expect(screen.getByText("Attempt #3")).toBeInTheDocument();
  });

  it("does not render Attempt line when current_retry_attempt is null", () => {
    render(<RunRail detail={fixture} />);
    expect(screen.queryByText(/Attempt #/)).not.toBeInTheDocument();
  });

  it("renders disabled Stop button with title", () => {
    render(<RunRail detail={fixture} />);
    const stopBtn = screen.getByRole("button", { name: /stop/i });
    expect(stopBtn).toBeDisabled();
    expect(stopBtn).toHaveAttribute("title", "Available soon");
  });

  it("renders disabled Retry now button with title", () => {
    render(<RunRail detail={fixture} />);
    const retryBtn = screen.getByRole("button", { name: /retry now/i });
    expect(retryBtn).toBeDisabled();
    expect(retryBtn).toHaveAttribute("title", "Available soon");
  });
});
