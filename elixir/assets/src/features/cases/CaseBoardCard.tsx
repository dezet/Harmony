import { ArrowRight, Check, TriangleAlert } from "lucide-react";
import { CaseAge, PriorityBadge } from "@/features/cases/CaseListItem";
import type { CaseSummary } from "@/types/contract";

// One Kanban card of layout A: a plain button, no drag handle. Opening it
// shows the same case detail as the list; it never starts an agent or changes
// the case. The project is named in text only, its color is identity, not health.

interface CaseBoardCardProps {
  item: CaseSummary;
  selected: boolean;
  now: number;
  onOpen: (ref: string) => void;
}

export function CaseBoardCard({ item, selected, now, onOpen }: CaseBoardCardProps) {
  const FootIcon = item.column === "handed_off" ? Check : ArrowRight;

  return (
    <li>
      <button
        type="button"
        aria-haspopup="dialog"
        aria-current={selected ? "true" : undefined}
        onClick={() => onOpen(item.ref)}
        className="block w-full rounded-[7px] border bg-card px-[13px] py-4 text-left outline-none transition-[border-color,transform] duration-150 hover:-translate-y-0.5 hover:border-primary focus-visible:border-primary focus-visible:ring-2 focus-visible:ring-ring/50 aria-[current=true]:border-t-2 aria-[current=true]:border-t-primary motion-reduce:transition-none motion-reduce:hover:translate-y-0 max-[600px]:p-[17px]"
      >
        <span className="flex items-center gap-[7px]">
          <span className="font-mono text-[11px] text-muted-foreground">{item.jira?.key ?? item.linear?.identifier}</span>
          <CaseAge detectedAt={item.detected_at} now={now} className="ml-auto text-[10px] text-muted-foreground" />
        </span>
        <span className="mt-2.5 flex">
          <PriorityBadge priority={item.priority} />
        </span>
        <span
          data-slot="case-title"
          className="my-[13px] block text-xs leading-[1.7] font-semibold text-foreground max-[600px]:text-sm"
        >
          {item.title}
        </span>
        {item.attention ? (
          <span className="mb-2.5 flex items-start gap-1.5 text-[10px] leading-[1.5] text-warning max-[600px]:text-[11px]">
            <TriangleAlert aria-hidden className="mt-px size-3 shrink-0" strokeWidth={1.8} />
            {item.attention.message}
          </span>
        ) : null}
        <span className="mb-[17px] block text-[10px] leading-[1.7] text-muted-foreground max-[600px]:text-[11px]">
          {item.status_label}
        </span>
        <span className="flex items-center gap-[7px] border-t pt-3 text-[10px] text-muted-foreground">
          <span className="truncate">{item.project.name}</span>
          <FootIcon aria-hidden className="ml-auto size-3.5 shrink-0" strokeWidth={1.6} />
        </span>
      </button>
    </li>
  );
}
