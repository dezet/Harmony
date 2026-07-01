import { render, screen } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { describe, it, expect, vi } from "vitest";
import { Combobox } from "@/components/Combobox";

const items = [
  { value: "a", label: "Alpha" },
  { value: "b", label: "Beta" },
];

describe("Combobox", () => {
  it("calls onOpen the first time it is opened", async () => {
    const onOpen = vi.fn();
    render(<Combobox items={items} value={null} onSelect={() => {}} onOpen={onOpen} label="Repo" />);
    await userEvent.click(screen.getByRole("combobox", { name: /repo/i }));
    expect(onOpen).toHaveBeenCalledTimes(1);
  });

  it("filters by query and selects an item", async () => {
    const onSelect = vi.fn();
    render(<Combobox items={items} value={null} onSelect={onSelect} onOpen={() => {}} label="Repo" />);
    const input = screen.getByRole("combobox", { name: /repo/i });
    await userEvent.click(input);
    await userEvent.type(input, "bet");
    expect(screen.queryByRole("option", { name: "Alpha" })).not.toBeInTheDocument();
    await userEvent.click(screen.getByRole("option", { name: "Beta" }));
    expect(onSelect).toHaveBeenCalledWith({ value: "b", label: "Beta" });
  });

  it("exposes the label as the combobox input's accessible name", () => {
    render(
      <Combobox
        items={items}
        value={{ value: "a", label: "Alpha" }}
        onSelect={() => {}}
        onOpen={() => {}}
        label="Repo"
      />,
    );
    expect(screen.getByRole("combobox", { name: /repo/i })).toBeInTheDocument();
  });
});
