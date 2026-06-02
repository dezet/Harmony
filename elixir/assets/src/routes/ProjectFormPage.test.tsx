import { render, screen, waitFor } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { MemoryRouter, Routes, Route } from "react-router-dom";
import { describe, it, expect, vi, afterEach } from "vitest";
import { ProjectFormPage } from "@/routes/ProjectFormPage";

afterEach(() => vi.restoreAllMocks());

function renderForm() {
  const qc = new QueryClient({
    defaultOptions: { queries: { retry: false }, mutations: { retry: false } },
  });
  return render(
    <QueryClientProvider client={qc}>
      <MemoryRouter initialEntries={["/projects/new"]}>
        <Routes>
          <Route path="/projects/new" element={<ProjectFormPage />} />
          <Route path="/projects" element={<div>Projects list</div>} />
        </Routes>
      </MemoryRouter>
    </QueryClientProvider>,
  );
}

describe("ProjectFormPage (create)", () => {
  it("shows a validation error when slug is empty", async () => {
    renderForm();
    await userEvent.click(screen.getByRole("button", { name: /save/i }));
    expect(await screen.findByText(/slug is required/i)).toBeInTheDocument();
  });

  it("submits and navigates to the list on success", async () => {
    vi.stubGlobal(
      "fetch",
      vi.fn(
        async () =>
          new Response(JSON.stringify({ project: { id: "1" } }), {
            status: 201,
            headers: { "content-type": "application/json" },
          }),
      ),
    );

    renderForm();
    await userEvent.type(screen.getByLabelText("Slug"), "portal");
    await userEvent.type(screen.getByLabelText("GitHub owner"), "dezet");
    await userEvent.type(screen.getByLabelText("GitHub repo"), "portal");
    await userEvent.type(screen.getByLabelText("Base branch"), "main");
    await userEvent.click(screen.getByRole("button", { name: /save/i }));

    await waitFor(() => expect(screen.getByText("Projects list")).toBeInTheDocument());
  });
});
