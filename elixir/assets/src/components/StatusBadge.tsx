import { Badge } from "@/components/ui/badge";

type Variant = "secondary" | "destructive" | "outline";

// Harmony run statuses (spec §11.3). An unknown historical status is shown
// verbatim, never hidden; the raw value stays in the title.
const STATUS: Record<string, { label: string; variant: Variant }> = {
  queued: { label: "W kolejce", variant: "outline" },
  running: { label: "W toku", variant: "outline" },
  retrying: { label: "Ponawianie", variant: "outline" },
  blocked: { label: "Zablokowany", variant: "destructive" },
  failed: { label: "Nieudany", variant: "destructive" },
  stopped: { label: "Zatrzymany", variant: "outline" },
  human_review: { label: "Przegląd człowieka", variant: "outline" },
  completed: { label: "Zakończony", variant: "secondary" },
  succeeded: { label: "Zakończony sukcesem", variant: "secondary" },
  handed_off: { label: "Przekazany", variant: "secondary" },
  cancelled: { label: "Anulowany", variant: "secondary" },
};

/** `raw` keeps external data (for example a forge CI status) untranslated. */
export function StatusBadge({ status, raw = false }: { status: string; raw?: boolean }) {
  const known = raw ? undefined : STATUS[status];
  return (
    <Badge variant={known?.variant ?? "outline"} title={status}>
      {known?.label ?? status}
    </Badge>
  );
}
