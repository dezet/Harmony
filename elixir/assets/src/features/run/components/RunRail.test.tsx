import { render, screen, act } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { describe, it, expect, vi, beforeEach } from "vitest";
import { RunRail } from "@/features/run/components/RunRail";
import type { RunDetail } from "@/types/contract";
import runDetailFixture from "@/test/fixtures/run_detail.fixture.json";

// ─── Mock useRunActions ───────────────────────────────────────────────────────

const stopMutate = vi.fn();
const retryMutate = vi.fn();

vi.mock("@/features/run/useRunActions", () => ({
  useStopRun: vi.fn(() => ({ mutate: stopMutate, isPending: false })),
  useRetryRun: vi.fn(() => ({ mutate: retryMutate, isPending: false })),
}));

// ─── Mock ConfirmDialog ───────────────────────────────────────────────────────
// AlertDialog uses a portal that doesn't render well in jsdom. Replace with a
// simple inline element that exposes the same logical interface so button-level
// assertions remain straightforward.

vi.mock("@/components/ConfirmDialog", () => ({
  ConfirmDialog: ({
    open,
    title,
    onConfirm,
    onOpenChange,
  }: {
    open: boolean;
    title: string;
    onConfirm: () => void;
    onOpenChange: (v: boolean) => void;
  }) =>
    open ? (
      <div role="dialog" aria-modal="true">
        <span>{title}</span>
        <button onClick={onConfirm}>Confirm</button>
        <button onClick={() => onOpenChange(false)}>Cancel</button>
      </div>
    ) : null,
}));

// ─── Fixtures ─────────────────────────────────────────────────────────────────

const fixture = runDetailFixture as RunDetail;
// fixture.status === "running"

const blockedDetail: RunDetail = { ...fixture, status: "blocked" };
const retryingDetail: RunDetail = {
  ...fixture,
  status: "retrying",
  attempts: { restart_count: 1, current_retry_attempt: 3 },
};
const completedDetail: RunDetail = { ...fixture, status: "completed" };

// ─── Tests ────────────────────────────────────────────────────────────────────

beforeEach(() => {
  vi.clearAllMocks();
});

describe("RunRail", () => {
  // ── Existing content tests (unchanged) ──────────────────────────────────────

  it("renders status badge", () => {
    render(<RunRail detail={fixture} />);
    expect(screen.getByText("running")).toBeInTheDocument();
  });

  it("renders turn_count", () => {
    render(<RunRail detail={fixture} />);
    expect(screen.getByText("7")).toBeInTheDocument();
  });

  it("renders last_event name", () => {
    render(<RunRail detail={fixture} />);
    expect(screen.getByText("turn_end")).toBeInTheDocument();
  });

  it("renders token totals when tokens present", () => {
    render(<RunRail detail={fixture} />);
    expect(screen.getByText("200")).toBeInTheDocument();
    expect(screen.getByText("80")).toBeInTheDocument();
    expect(screen.getByText("280")).toBeInTheDocument();
  });

  it("renders 'No token data.' when tokens are null", () => {
    render(<RunRail detail={{ ...fixture, tokens: null }} />);
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
    expect(screen.getByText("screenshot")).toBeInTheDocument();
    expect(screen.getByText("/artifacts/screen.png")).toBeInTheDocument();
  });

  it("renders 'No artifacts.' when artifact list is empty", () => {
    render(<RunRail detail={{ ...fixture, artifacts: [] }} />);
    expect(screen.getByText("No artifacts.")).toBeInTheDocument();
  });

  it("renders workspace path in mono", () => {
    render(<RunRail detail={fixture} />);
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

  // ── Stop button ─────────────────────────────────────────────────────────────

  it("Stop button has aria-label 'Stop this run'", () => {
    render(<RunRail detail={fixture} />);
    expect(
      screen.getByRole("button", { name: "Stop this run" }),
    ).toBeInTheDocument();
  });

  it("Stop button is enabled when status is 'running'", () => {
    render(<RunRail detail={fixture} />);
    expect(screen.getByRole("button", { name: "Stop this run" })).not.toBeDisabled();
  });

  it("Stop button is enabled when status is 'blocked'", () => {
    render(<RunRail detail={blockedDetail} />);
    expect(screen.getByRole("button", { name: "Stop this run" })).not.toBeDisabled();
  });

  it("Stop button is disabled for a terminal status", () => {
    render(<RunRail detail={completedDetail} />);
    expect(screen.getByRole("button", { name: "Stop this run" })).toBeDisabled();
  });

  it("clicking Stop button opens the confirm dialog", async () => {
    const user = userEvent.setup();
    render(<RunRail detail={fixture} />);
    expect(screen.queryByRole("dialog")).not.toBeInTheDocument();
    await user.click(screen.getByRole("button", { name: "Stop this run" }));
    expect(screen.getByRole("dialog")).toBeInTheDocument();
    expect(screen.getByText("Stop this run?")).toBeInTheDocument();
  });

  it("confirming the dialog calls stop.mutate", async () => {
    const user = userEvent.setup();
    render(<RunRail detail={fixture} />);
    await user.click(screen.getByRole("button", { name: "Stop this run" }));
    await user.click(screen.getByRole("button", { name: "Confirm" }));
    expect(stopMutate).toHaveBeenCalledTimes(1);
  });

  it("cancelling the dialog does not call stop.mutate", async () => {
    const user = userEvent.setup();
    render(<RunRail detail={fixture} />);
    await user.click(screen.getByRole("button", { name: "Stop this run" }));
    await user.click(screen.getByRole("button", { name: "Cancel" }));
    expect(stopMutate).not.toHaveBeenCalled();
    expect(screen.queryByRole("dialog")).not.toBeInTheDocument();
  });

  it("confirming the dialog closes it via onSettled callback passed to mutate", async () => {
    // ConfirmDialog no longer auto-closes on confirm (the Close primitive was replaced
    // with a plain Button). RunRail must pass onSettled: () => setConfirmOpen(false)
    // to stop.mutate so the dialog closes after the mutation settles.
    let capturedOnSettled: (() => void) | undefined;
    stopMutate.mockImplementation((_arg: unknown, opts?: { onSettled?: () => void }) => {
      capturedOnSettled = opts?.onSettled;
    });

    const user = userEvent.setup();
    render(<RunRail detail={fixture} />);
    await user.click(screen.getByRole("button", { name: "Stop this run" }));
    expect(screen.getByRole("dialog")).toBeInTheDocument();
    await user.click(screen.getByRole("button", { name: "Confirm" }));
    // mutate was called with an onSettled callback
    expect(capturedOnSettled).toBeDefined();
    // simulate the mutation settling — the dialog should close
    await act(async () => { capturedOnSettled!(); });
    expect(screen.queryByRole("dialog")).not.toBeInTheDocument();
  });

  // ── Retry button ─────────────────────────────────────────────────────────────

  it("Retry button has aria-label 'Retry this run now'", () => {
    render(<RunRail detail={fixture} />);
    expect(
      screen.getByRole("button", { name: "Retry this run now" }),
    ).toBeInTheDocument();
  });

  it("Retry button is enabled only when status is 'retrying'", () => {
    render(<RunRail detail={retryingDetail} />);
    expect(
      screen.getByRole("button", { name: "Retry this run now" }),
    ).not.toBeDisabled();
  });

  it("Retry button is disabled when status is 'running'", () => {
    render(<RunRail detail={fixture} />);
    expect(screen.getByRole("button", { name: "Retry this run now" })).toBeDisabled();
  });

  it("Retry button is disabled for a terminal status", () => {
    render(<RunRail detail={completedDetail} />);
    expect(screen.getByRole("button", { name: "Retry this run now" })).toBeDisabled();
  });

  it("clicking Retry button calls retry.mutate directly (no dialog)", async () => {
    const user = userEvent.setup();
    render(<RunRail detail={retryingDetail} />);
    await user.click(screen.getByRole("button", { name: "Retry this run now" }));
    expect(retryMutate).toHaveBeenCalledTimes(1);
    expect(screen.queryByRole("dialog")).not.toBeInTheDocument();
  });
});
