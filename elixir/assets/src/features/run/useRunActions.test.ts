import { describe, it, expect, vi, afterEach } from "vitest";
import { renderHook, act, waitFor } from "@testing-library/react";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { createElement } from "react";
import { useStopRun, useRetryRun } from "@/features/run/useRunActions";
import * as api from "@/lib/api";
import { RUN_KEY } from "@/lib/queryClient";

vi.mock("sonner", () => ({
  toast: { success: vi.fn(), error: vi.fn() },
}));

afterEach(() => vi.restoreAllMocks());

function makeWrapper() {
  const qc = new QueryClient({
    defaultOptions: { queries: { retry: false }, mutations: { retry: false } },
  });
  const wrapper = ({ children }: { children: React.ReactNode }) =>
    createElement(QueryClientProvider, { client: qc }, children);
  return { qc, wrapper };
}

describe("useStopRun", () => {
  it("calls stopRun, shows success toast, and invalidates RUN_KEY on success", async () => {
    const { qc, wrapper } = makeWrapper();
    const stopRunSpy = vi.spyOn(api, "stopRun").mockResolvedValue({ status: "stopped" });
    const invalidateSpy = vi.spyOn(qc, "invalidateQueries");

    const { result } = renderHook(() => useStopRun("COD-10"), { wrapper });

    act(() => {
      result.current.mutate();
    });

    await waitFor(() => expect(result.current.isSuccess).toBe(true));

    expect(stopRunSpy).toHaveBeenCalledWith("COD-10");

    const { toast } = await import("sonner");
    expect(toast.success).toHaveBeenCalledWith("Run stop requested");
    expect(invalidateSpy).toHaveBeenCalledWith({ queryKey: RUN_KEY("COD-10") });
  });

  it("shows error toast with ApiError code on failure", async () => {
    const { wrapper } = makeWrapper();
    vi.spyOn(api, "stopRun").mockRejectedValue(
      new api.ApiError(404, "run_not_found", "Run not found"),
    );

    const { result } = renderHook(() => useStopRun("COD-10"), { wrapper });

    act(() => {
      result.current.mutate();
    });

    await waitFor(() => expect(result.current.isError).toBe(true));

    const { toast } = await import("sonner");
    expect(toast.error).toHaveBeenCalledWith("Failed to stop run (run_not_found)");
  });

  it("shows error toast with 'unknown' code for non-ApiError failures", async () => {
    const { wrapper } = makeWrapper();
    vi.spyOn(api, "stopRun").mockRejectedValue(new Error("network error"));

    const { result } = renderHook(() => useStopRun("COD-10"), { wrapper });

    act(() => {
      result.current.mutate();
    });

    await waitFor(() => expect(result.current.isError).toBe(true));

    const { toast } = await import("sonner");
    expect(toast.error).toHaveBeenCalledWith("Failed to stop run (unknown)");
  });
});

describe("useRetryRun", () => {
  it("calls retryRun, shows success toast, and invalidates RUN_KEY on success", async () => {
    const { qc, wrapper } = makeWrapper();
    const retryRunSpy = vi.spyOn(api, "retryRun").mockResolvedValue({ status: "retrying" });
    const invalidateSpy = vi.spyOn(qc, "invalidateQueries");

    const { result } = renderHook(() => useRetryRun("COD-10"), { wrapper });

    act(() => {
      result.current.mutate();
    });

    await waitFor(() => expect(result.current.isSuccess).toBe(true));

    expect(retryRunSpy).toHaveBeenCalledWith("COD-10");

    const { toast } = await import("sonner");
    expect(toast.success).toHaveBeenCalledWith("Retry scheduled");
    expect(invalidateSpy).toHaveBeenCalledWith({ queryKey: RUN_KEY("COD-10") });
  });

  it("shows error toast with ApiError code on failure", async () => {
    const { wrapper } = makeWrapper();
    vi.spyOn(api, "retryRun").mockRejectedValue(
      new api.ApiError(409, "not_retrying", "Run is not retrying"),
    );

    const { result } = renderHook(() => useRetryRun("COD-10"), { wrapper });

    act(() => {
      result.current.mutate();
    });

    await waitFor(() => expect(result.current.isError).toBe(true));

    const { toast } = await import("sonner");
    expect(toast.error).toHaveBeenCalledWith("Failed to retry run (not_retrying)");
  });

  it("shows error toast with 'unknown' code for non-ApiError failures", async () => {
    const { wrapper } = makeWrapper();
    vi.spyOn(api, "retryRun").mockRejectedValue(new Error("network error"));

    const { result } = renderHook(() => useRetryRun("COD-10"), { wrapper });

    act(() => {
      result.current.mutate();
    });

    await waitFor(() => expect(result.current.isError).toBe(true));

    const { toast } = await import("sonner");
    expect(toast.error).toHaveBeenCalledWith("Failed to retry run (unknown)");
  });
});
