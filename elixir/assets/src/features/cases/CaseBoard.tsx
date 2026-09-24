import { useNow } from "@/lib/useNow";
import { CaseColumn } from "@/features/cases/CaseColumn";
import { CASE_COLUMNS } from "@/features/cases/useCases";
import type { CaseFilters } from "@/types/contract";

// Kanban of layout A (spec §4.5): the four columns in a fixed order over the
// same filters as the list. Four columns above 1150 px, two up to 1150 px, one
// up to 600 px. Plain cards only: no drag and drop and no status changes.

interface CaseBoardProps {
  filters: CaseFilters;
  selectedRef: string | null;
  onOpen: (ref: string) => void;
}

export function CaseBoard({ filters, selectedRef, onOpen }: CaseBoardProps) {
  const now = useNow(60_000);

  return (
    <section aria-label="Kanban spraw">
      <div
        data-slot="board-columns"
        className="grid grid-cols-4 items-start gap-4 max-[1150px]:grid-cols-2 max-[1150px]:gap-2.5 max-[600px]:grid-cols-1"
      >
        {CASE_COLUMNS.map((column) => (
          <CaseColumn
            key={column}
            column={column}
            filters={filters}
            selectedRef={selectedRef}
            now={now}
            onOpen={onOpen}
          />
        ))}
      </div>
    </section>
  );
}
