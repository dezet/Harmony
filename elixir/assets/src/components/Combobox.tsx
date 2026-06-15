import { useState } from "react";
import { Input } from "@/components/ui/input";
import { Button } from "@/components/ui/button";

export interface ComboboxItem {
  value: string;
  label: string;
}

interface ComboboxProps {
  items: ComboboxItem[];
  value: ComboboxItem | null;
  onSelect: (item: ComboboxItem) => void;
  onOpen: () => void;
  label: string;
  loading?: boolean;
  error?: string | null;
  disabled?: boolean;
}

export function Combobox({
  items,
  value,
  onSelect,
  onOpen,
  label,
  loading,
  error,
  disabled,
}: ComboboxProps) {
  const [open, setOpen] = useState(false);
  const [query, setQuery] = useState("");
  const [openedOnce, setOpenedOnce] = useState(false);

  function toggle() {
    const next = !open;
    setOpen(next);
    if (next && !openedOnce) {
      setOpenedOnce(true);
      onOpen();
    }
  }

  const filtered = items.filter((i) =>
    i.label.toLowerCase().includes(query.trim().toLowerCase()),
  );

  return (
    <div className="relative">
      <Button
        type="button"
        variant="outline"
        onClick={toggle}
        disabled={disabled}
        aria-label={value ? `${label}: ${value.label}` : label}
      >
        {value ? value.label : label}
      </Button>
      {open ? (
        <div
          role="listbox"
          className="absolute z-10 mt-1 w-full rounded-md border bg-popover p-1 shadow-md"
        >
          <Input
            autoFocus
            value={query}
            placeholder="Search…"
            onChange={(e) => setQuery(e.target.value)}
            aria-label={`${label} search`}
          />
          {loading ? <p className="p-2 text-sm text-muted-foreground">Loading…</p> : null}
          {error ? <p className="p-2 text-sm text-destructive">{error}</p> : null}
          {!loading && !error
            ? filtered.map((item) => (
                <button
                  key={item.value}
                  type="button"
                  role="option"
                  aria-selected={value?.value === item.value}
                  className="block w-full rounded px-2 py-1 text-left text-sm hover:bg-accent"
                  onClick={() => {
                    onSelect(item);
                    setOpen(false);
                    setQuery("");
                  }}
                >
                  {item.label}
                </button>
              ))
            : null}
        </div>
      ) : null}
    </div>
  );
}
