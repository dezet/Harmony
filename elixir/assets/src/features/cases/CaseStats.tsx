import { Clock } from "lucide-react";
import { Skeleton } from "@/components/ui/skeleton";
import { useNow } from "@/lib/useNow";
import type { RuleSchedule } from "@/features/automations/useAutomations";
import type { CaseCounts } from "@/types/contract";

// Stats line of layout A. The numbers are aggregates of the selected project,
// independent of the search and the active filter (spec §4.4); they never
// count the loaded page.

interface CaseStatsProps {
  counts: CaseCounts | undefined;
  countsError: boolean;
  schedule: RuleSchedule | null;
  scheduleError: boolean;
}

const timeFormat = new Intl.DateTimeFormat("pl-PL", { hour: "2-digit", minute: "2-digit" });
const fullFormat = new Intl.DateTimeFormat("pl-PL", { dateStyle: "full", timeStyle: "medium" });

function Stat({ value, label }: { value: number | undefined; label: string }) {
  return (
    <span className="flex items-baseline">
      {value === undefined ? (
        <Skeleton aria-hidden className="mr-1.5 h-[19px] w-4 self-center" />
      ) : (
        <>
          <strong className="mr-1.5 text-[19px] font-semibold text-foreground tabular-nums max-[600px]:mr-1 max-[600px]:text-[17px]">
            {value}
          </strong>{" "}
        </>
      )}
      {label}
    </span>
  );
}

function minutesUntil(iso: string, now: number): number {
  return Math.ceil((new Date(iso).getTime() - now) / 60_000);
}

function ScheduleText({ schedule, error, now }: { schedule: RuleSchedule | null; error: boolean; now: number }) {
  if (error) return <>Stan reguł jest niedostępny</>;
  if (!schedule) return <>Wczytywanie stanu reguł…</>;
  if (schedule.kind === "none") return <>Brak aktywnych reguł</>;

  const { lastCheckAt, nextCheckAt } = schedule;
  const next = nextCheckAt ? minutesUntil(nextCheckAt, now) : null;
  const nextText =
    next === null ? null : next > 0 ? `Kolejne sprawdzenie za ${next} min` : "Kolejne sprawdzenie wkrótce";

  if (!lastCheckAt && !nextText) return <>Reguły aktywne, oczekiwanie na pierwsze sprawdzenie</>;

  return (
    <>
      {lastCheckAt ? (
        <time dateTime={lastCheckAt} title={fullFormat.format(new Date(lastCheckAt))}>
          Ostatnie sprawdzenie {timeFormat.format(new Date(lastCheckAt))}
        </time>
      ) : null}
      {lastCheckAt && nextText ? <span aria-hidden>·</span> : null}
      {nextText && nextCheckAt ? (
        <time dateTime={nextCheckAt} title={fullFormat.format(new Date(nextCheckAt))}>
          {nextText}
        </time>
      ) : null}
    </>
  );
}

export function CaseStats({ counts, countsError, schedule, scheduleError }: CaseStatsProps) {
  const now = useNow(30_000);

  return (
    <section
      aria-label="Podsumowanie spraw"
      className="flex items-center gap-[26px] border-t pt-4 pb-[21px] text-[11px] text-muted-foreground max-[1150px]:gap-[15px] max-[600px]:flex-wrap max-[600px]:justify-between max-[600px]:gap-[13px] max-[600px]:pt-3.5 max-[600px]:pb-[17px] max-[600px]:text-[10px]"
    >
      {countsError ? (
        <span className="text-destructive">Nie udało się wczytać liczników spraw</span>
      ) : (
        <>
          <Stat value={counts?.decision} label="do Twojej decyzji" />
          <Stat value={counts?.analysis} label="analiza w toku" />
          <Stat value={counts?.detected} label="w kolejce" />
        </>
      )}
      <span className="ml-auto flex items-center gap-1.5 max-[600px]:ml-0 max-[600px]:basis-full">
        <Clock aria-hidden className="size-3.5" strokeWidth={1.6} />
        <ScheduleText schedule={schedule} error={scheduleError} now={now} />
      </span>
    </section>
  );
}
