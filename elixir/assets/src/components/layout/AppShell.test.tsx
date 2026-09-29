import { render, screen, waitFor, within } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { MemoryRouter, Route, Routes } from "react-router-dom";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { describe, it, expect, vi, afterEach } from "vitest";
import { AppShell } from "@/components/layout/AppShell";
import { ThemeProvider } from "@/components/theme/ThemeProvider";
import { DashboardConnectionProvider } from "@/lib/dashboardConnection";
import { makeFakeSocket, type FakeSocket } from "@/test/fakeSocket";

let fakeSocket: FakeSocket = makeFakeSocket();

vi.mock("@/lib/socket", async (importOriginal) => {
  const original = await importOriginal<typeof import("@/lib/socket")>();
  return { ...original, getSocket: () => fakeSocket };
});

afterEach(() => {
  vi.restoreAllMocks();
  fakeSocket = makeFakeSocket();
  localStorage.clear();
  document.documentElement.classList.remove("dark");
});

function stubApi() {
  vi.stubGlobal(
    "fetch",
    vi.fn(async (input: RequestInfo | URL) => {
      const url = String(input);
      const body = url.includes("/api/v1/projects")
        ? { projects: [] }
        : {
            items: [],
            meta: { next_cursor: null, total: 0, page_size: 1 },
            counts: { all: 0, decision: 0, analysis: 0, done: 0, detected: 0 },
            project_counts: [],
          };
      return new Response(JSON.stringify(body), {
        status: 200,
        headers: { "content-type": "application/json" },
      });
    }),
  );
}

function renderShell(path = "/") {
  stubApi();
  const qc = new QueryClient({ defaultOptions: { queries: { retry: false } } });
  return render(
    <ThemeProvider>
      <QueryClientProvider client={qc}>
        <DashboardConnectionProvider initialStatus="live">
          <MemoryRouter initialEntries={[path]}>
            <Routes>
              <Route element={<AppShell />}>
                <Route index element={<h1>Strona startowa</h1>} />
                <Route path="automations" element={<h1>Strona automatyzacji</h1>} />
              </Route>
            </Routes>
          </MemoryRouter>
        </DashboardConnectionProvider>
      </QueryClientProvider>
    </ThemeProvider>,
  );
}

describe("AppShell", () => {
  it("renders the desktop sidebar, the breadcrumb header and the main landmark", () => {
    renderShell();

    expect(screen.getByRole("navigation", { name: "Główna" })).toBeInTheDocument();
    expect(screen.getByRole("navigation", { name: "Ścieżka" })).toBeInTheDocument();
    expect(screen.getByRole("main")).toHaveAttribute("id", "main");
    expect(screen.getByRole("link", { name: "Przejdź do treści" })).toHaveAttribute("href", "#main");
  });

  it("has no concept switcher, prototype labels or demo profile", () => {
    const { container } = renderShell();

    for (const demo of [/Centrum spraw.*Polecany/, /DESIGN EXPLORATION/i, /Prototyp/, /PODGLĄD/i, /Daniel/]) {
      expect(screen.queryByText(demo)).not.toBeInTheDocument();
    }
    expect(container.querySelector("[data-concept]")).toBeNull();
    expect(screen.queryByRole("navigation", { name: "Wariant projektu" })).not.toBeInTheDocument();
  });

  it("opens the mobile menu as a dialog, traps Escape and restores focus", async () => {
    const user = userEvent.setup();
    renderShell();

    const trigger = screen.getByRole("button", { name: "Otwórz menu" });
    expect(trigger).toHaveAttribute("aria-expanded", "false");
    await user.click(trigger);

    const dialog = await screen.findByRole("dialog", { name: "Menu nawigacji" });
    expect(trigger).toHaveAttribute("aria-expanded", "true");
    expect(within(dialog).getByRole("navigation", { name: "Główna" })).toBeInTheDocument();
    expect(within(dialog).getByRole("link", { name: "Automatyzacje" })).toBeInTheDocument();
    await waitFor(() => expect(dialog).toContainElement(document.activeElement as HTMLElement));

    await user.keyboard("{Escape}");
    await waitFor(() => expect(screen.queryByRole("dialog")).not.toBeInTheDocument());
    await waitFor(() => expect(trigger).toHaveFocus());
  });

  it("closes the mobile menu with a visible X icon button named Zamknij menu", async () => {
    const user = userEvent.setup();
    renderShell();

    const trigger = screen.getByRole("button", { name: "Otwórz menu" });
    await user.click(trigger);
    const dialog = await screen.findByRole("dialog", { name: "Menu nawigacji" });
    const close = within(dialog).getByRole("button", { name: "Zamknij menu" });

    // An icon button like the case detail close: no visible text, never hidden until focus.
    expect(close).toHaveAttribute("aria-label", "Zamknij menu");
    expect(close).toHaveTextContent(/^$/);
    expect(close.querySelector("svg.lucide-x")).toHaveAttribute("aria-hidden", "true");
    expect(close).not.toHaveClass("sr-only");

    close.focus();
    await user.keyboard("{Enter}");
    await waitFor(() => expect(screen.queryByRole("dialog")).not.toBeInTheDocument());
    await waitFor(() => expect(trigger).toHaveFocus());
  });

  it("closes the mobile menu after choosing a destination", async () => {
    const user = userEvent.setup();
    renderShell();

    await user.click(screen.getByRole("button", { name: "Otwórz menu" }));
    const dialog = await screen.findByRole("dialog", { name: "Menu nawigacji" });
    await user.click(within(dialog).getByRole("link", { name: "Automatyzacje" }));

    await waitFor(() => expect(screen.queryByRole("dialog")).not.toBeInTheDocument());
    expect(screen.getByRole("heading", { name: "Strona automatyzacji" })).toBeInTheDocument();
  });

  it("keeps layout A in dark mode instead of switching to another concept", async () => {
    const user = userEvent.setup();
    const { container } = renderShell();
    const landmarks = () =>
      [
        screen.getAllByRole("navigation").map((nav) => nav.getAttribute("aria-label")),
        screen.getByRole("main").id,
      ].flat();
    const before = landmarks();
    const shellClass = (container.firstElementChild as HTMLElement).className;

    await user.click(screen.getByRole("button", { name: "Włącz tryb ciemny" }));

    expect(document.documentElement.classList.contains("dark")).toBe(true);
    expect(landmarks()).toEqual(before);
    expect((container.firstElementChild as HTMLElement).className).toBe(shellClass);
    expect(container.querySelector("[data-concept]")).toBeNull();
    expect(screen.getByRole("button", { name: "Włącz tryb jasny" })).toBeInTheDocument();
  });
});
