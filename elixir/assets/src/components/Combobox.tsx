import { useRef, useState } from "react";
import {
  Combobox as ComboboxRoot,
  ComboboxContent,
  ComboboxEmpty,
  ComboboxInput,
  ComboboxItem as ComboboxOption,
  ComboboxList,
} from "@/components/ui/combobox";

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

/**
 * Thin wrapper over the shadcn (base-nova) Combobox primitive that adds the
 * picker glue this app needs: lazy data load on first open, loading/error
 * states, and a search box that is decoupled from the selected value (the
 * input is cleared on open so every item is listed regardless of selection).
 */
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
  const openedOnce = useRef(false);
  const [query, setQuery] = useState("");

  return (
    <ComboboxRoot
      items={items}
      value={value}
      onValueChange={(next: ComboboxItem | null) => {
        if (next) onSelect(next);
      }}
      inputValue={query}
      onInputValueChange={(next: string) => setQuery(next)}
      isItemEqualToValue={(a: ComboboxItem, b: ComboboxItem) => a?.value === b?.value}
      onOpenChange={(open: boolean) => {
        if (open) {
          setQuery("");
          if (!openedOnce.current) {
            openedOnce.current = true;
            onOpen();
          }
        }
      }}
      disabled={disabled}
    >
      <ComboboxInput aria-label={label} placeholder={label} disabled={disabled} />
      <ComboboxContent>
        <ComboboxEmpty>
          {loading ? (
            "Loading…"
          ) : error ? (
            <span className="text-destructive">{error}</span>
          ) : (
            "No results."
          )}
        </ComboboxEmpty>
        <ComboboxList>
          {(item: ComboboxItem) => (
            <ComboboxOption key={item.value} value={item}>
              {item.label}
            </ComboboxOption>
          )}
        </ComboboxList>
      </ComboboxContent>
    </ComboboxRoot>
  );
}
