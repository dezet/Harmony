import { render, screen, within } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { describe, it, expect, vi } from "vitest";
import { type ColumnDef } from "@tanstack/react-table";
import { DataTable } from "@/components/DataTable";

type Person = { name: string; age: number };

const columns: ColumnDef<Person, unknown>[] = [
  {
    accessorKey: "name",
    header: "Name",
    enableSorting: true,
  },
  {
    accessorKey: "age",
    header: "Age",
    enableSorting: true,
  },
];

const data: Person[] = [
  { name: "Alice", age: 30 },
  { name: "Charlie", age: 25 },
  { name: "Bob", age: 35 },
];

describe("DataTable", () => {
  it("renders rows from data and columns", () => {
    render(<DataTable columns={columns} data={data} />);
    expect(screen.getByText("Alice")).toBeInTheDocument();
    expect(screen.getByText("Charlie")).toBeInTheDocument();
    expect(screen.getByText("Bob")).toBeInTheDocument();
    expect(screen.getByText("Name")).toBeInTheDocument();
    expect(screen.getByText("Age")).toBeInTheDocument();
  });

  it("clicking a sortable header toggles row order", async () => {
    const user = userEvent.setup();
    render(<DataTable columns={columns} data={data} />);

    // Initially unsorted — rows in insertion order: Alice, Charlie, Bob
    const rowsBefore = screen.getAllByRole("row").slice(1); // skip header row
    expect(within(rowsBefore[0]).getByText("Alice")).toBeInTheDocument();
    expect(within(rowsBefore[1]).getByText("Charlie")).toBeInTheDocument();
    expect(within(rowsBefore[2]).getByText("Bob")).toBeInTheDocument();

    // Click "Name" header to sort ascending
    await user.click(screen.getByRole("button", { name: /name/i }));

    const rowsAsc = screen.getAllByRole("row").slice(1);
    const firstCellsAsc = rowsAsc.map((r) => r.querySelectorAll("td")[0].textContent);
    expect(firstCellsAsc).toEqual(["Alice", "Bob", "Charlie"]);

    // Click again to sort descending
    await user.click(screen.getByRole("button", { name: /name/i }));

    const rowsDesc = screen.getAllByRole("row").slice(1);
    const firstCellsDesc = rowsDesc.map((r) => r.querySelectorAll("td")[0].textContent);
    expect(firstCellsDesc).toEqual(["Charlie", "Bob", "Alice"]);
  });

  it("renders empty state message when data is empty and not loading", () => {
    render(<DataTable columns={columns} data={[]} emptyMessage="Nothing here." />);
    expect(screen.getByText("Nothing here.")).toBeInTheDocument();
  });

  it("renders default empty state message when emptyMessage not provided", () => {
    render(<DataTable columns={columns} data={[]} />);
    expect(screen.getByText("No rows.")).toBeInTheDocument();
  });

  it("does not render Load more button when hasNextPage is false", () => {
    render(<DataTable columns={columns} data={data} hasNextPage={false} />);
    expect(screen.queryByRole("button", { name: /load more/i })).not.toBeInTheDocument();
  });

  it("renders Load more button when hasNextPage is true", () => {
    render(<DataTable columns={columns} data={data} hasNextPage={true} onLoadMore={vi.fn()} />);
    expect(screen.getByRole("button", { name: /load more/i })).toBeInTheDocument();
  });

  it("calls onLoadMore when Load more is clicked", async () => {
    const user = userEvent.setup();
    const onLoadMore = vi.fn();
    render(<DataTable columns={columns} data={data} hasNextPage={true} onLoadMore={onLoadMore} />);
    await user.click(screen.getByRole("button", { name: /load more/i }));
    expect(onLoadMore).toHaveBeenCalledOnce();
  });

  it("disables Load more button when isLoading is true", () => {
    render(
      <DataTable
        columns={columns}
        data={data}
        hasNextPage={true}
        onLoadMore={vi.fn()}
        isLoading={true}
      />
    );
    expect(screen.getByRole("button", { name: /load more/i })).toBeDisabled();
  });
});
