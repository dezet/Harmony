import { TriangleAlert } from "lucide-react";
import { cn } from "@/lib/utils";
import type { CaseColumn, CasePriority, CaseSummary } from "@/types/contract";

// One ticket of the list (layout A). The status badge follows the Kanban
// column; the project is named in text only, its color is identity, not health.

const badge = "inline-flex items-center gap-[5px] rounded-[5px] px-[7px] py-1 text-[10px] leading-[1.25] font-[550] whitespace-nowrap";

const columnTone: Record<CaseColumn, string> = {
  detected: "bg-muted text-muted-foreground",
  analyzing: "bg-accent text-accent-foreground",
  decision: "bg-warning-surface text-warning",
  handed_off: "bg-success-surface text-success",
};

const fullDate = new Intl.DateTimeFormat("pl-PL", { dateStyle: "full", timeStyle: "medium" });

/** Age since detection: "12 min", "3 godz.", "2 dni". */
function caseAge(detectedAt: string, now: number): string {
  const minutes = Math.max(0, Math.floor((now - new Date(detectedAt).getTime()) / 60_000));
  if (minutes < 60) return `${minutes} min`;
  const hours = Math.floor(minutes / 60);
  if (hours < 24) return `${hours} godz.`;
  const days = Math.floor(hours / 24);
  return days === 1 ? "1 dzień" : `${days} dni`;
}

function PriorityBadge({ priority }: { priority: CasePriority }) {
  const critical = priority.tone === "critical";
  const marker = critical ? "!!" : priority.tone === "high" ? "↑" : null;

  return (
    <span className={cn(badge, critical ? "bg-destructive-surface text-destructive" : "bg-muted text-muted-foreground")}>
      {marker ? <span aria-hidden>{marker}</span> : null}
      {priority.label}
    </span>
  );
}

function SourceKey({ item }: { item: CaseSummary }) {
  if (item.jira) {
    return (
      <>
        <span aria-hidden className="inline-block size-2.5 shrink-0 rotate-45 rounded-[1px] bg-[#3976d0]" />
        <span className="font-mono text-[11px] text-muted-foreground">{item.jira.key}</span>
      </>
    );
  }
  if (item.linear) {
    return (
      <>
        <span
          aria-hidden
          className="inline-block size-[11px] shrink-0 rounded-full bg-[repeating-linear-gradient(45deg,#8a82da_0px,#8a82da_2px,transparent_2px,transparent_3px)]"
        />
        <span className="font-mono text-[11px] text-muted-foreground">{item.linear.identifier}</span>
      </>
    );
  }
  return null;
}

interface CaseListItemProps {
  item: CaseSummary;
  selected: boolean;
  now: number;
  onSelect: (ref: string) => void;
}

export function CaseListItem({ item, selected, now, onSelect }: CaseListItemProps) {
  return (
    <li className="border-b last:border-b-0">
      <button
        type="button"
        aria-pressed={selected}
        onClick={() => onSelect(item.ref)}
        className="block min-h-[119px] w-full border-l-[3px] border-l-transparent px-[19px] py-[18px] text-left outline-none hover:bg-background focus-visible:ring-2 focus-visible:ring-ring/50 focus-visible:ring-inset aria-pressed:border-l-primary aria-pressed:bg-accent max-[600px]:min-h-[113px] max-[600px]:p-[17px] min-[1600px]:p-[22px]"
      >
        <span className="mb-2.5 flex items-center gap-[7px]">
          <SourceKey item={item} />
          <PriorityBadge priority={item.priority} />
          <time
            dateTime={item.detected_at}
            title={fullDate.format(new Date(item.detected_at))}
            className="ml-auto text-[10px] text-muted-foreground"
          >
            {caseAge(item.detected_at, now)}
          </time>
        </span>
        <span data-slot="case-title" className="mb-2.5 block text-xs leading-[1.5] font-semibold text-foreground">
          {item.title}
        </span>
        {item.attention ? (
          <span className="mb-2.5 flex items-start gap-1.5 text-[10px] leading-[1.5] text-warning">
            <TriangleAlert aria-hidden className="mt-px size-3 shrink-0" strokeWidth={1.8} />
            {item.attention.message}
          </span>
        ) : null}
        <span className="flex items-center gap-[7px] text-[10px] text-muted-foreground">
          <span className={cn(badge, columnTone[item.column])}>{item.status_label}</span>
          <span className="ml-auto truncate">{item.project.name}</span>
        </span>
      </button>
    </li>
  );
}
