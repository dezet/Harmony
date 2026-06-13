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
    await userEvent.click(screen.getByRole("button", { name: /repo/i }));
    expect(onOpen).toHaveBeenCalledTimes(1);
  });

  it("filters by query and selects an item", async () => {
    const onSelect = vi.fn();
    render(<Combobox items={items} value={null} onSelect={onSelect} onOpen={() => {}} label="Repo" />);
    await userEvent.click(screen.getByRole("button", { name: /repo/i }));
    await userEvent.type(screen.getByRole("textbox"), "bet");
    expect(screen.queryByRole("option", { name: "Alpha" })).not.toBeInTheDocument();
    await userEvent.click(screen.getByRole("option", { name: "Beta" }));
    expect(onSelect).toHaveBeenCalledWith({ value: "b", label: "Beta" });
  });

  it("shows the current value as the button label", () => {
    render(
      <Combobox
        items={items}
        value={{ value: "a", label: "Alpha" }}
        onSelect={() => {}}
        onOpen={() => {}}
        label="Repo"
      />,
    );
    expect(screen.getByRole("button", { name: /alpha/i })).toBeInTheDocument();
  });
});
