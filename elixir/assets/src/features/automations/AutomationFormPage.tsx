import { useEffect } from "react";
import { Link, useParams } from "react-router-dom";
import { Button } from "@/components/ui/button";
import { Skeleton } from "@/components/ui/skeleton";
import { ApiError } from "@/lib/api";
import { AutomationForm } from "@/features/automations/AutomationForm";
import { automationErrorMessage, useAutomation } from "@/features/automations/useAutomations";

// `/automations/new` and `/automations/:id` (spec §4.3). The form is keyed by
// the rule, so saving a new rule remounts it on the rule's own URL.

function Heading({ title }: { title: string }) {
  useEffect(() => {
    document.title = `${title} — Harmony`;
  }, [title]);
  return <h1 className="text-title max-[1150px]:text-[26px] max-[600px]:text-[27px]">{title}</h1>;
}

export function AutomationFormPage() {
  const { id } = useParams();
  const rule = useAutomation(id);

  if (!id) return <AutomationForm key="new" />;

  if (rule.isPending) {
    return (
      <div className="grid gap-4">
        <Heading title="Reguła" />
        <Skeleton className="h-[520px] w-full rounded-[10px]" />
      </div>
    );
  }

  if (rule.isError) {
    const missing = rule.error instanceof ApiError && rule.error.status === 404;
    return (
      <div className="grid justify-items-start gap-2">
        <Heading title={missing ? "Nie znaleziono reguły" : "Nie udało się wczytać reguły"} />
        <p className="text-xs leading-[1.6] text-muted-foreground">
          {missing ? "Reguła nie istnieje albo została usunięta." : automationErrorMessage(rule.error)}
        </p>
        <div className="flex flex-wrap gap-3">
          {missing ? null : (
            <Button type="button" variant="outline" size="sm" onClick={() => void rule.refetch()}>
              Spróbuj ponownie
            </Button>
          )}
          <Link className="text-xs text-primary underline underline-offset-4" to="/automations">
            Wróć do listy reguł
          </Link>
        </div>
      </div>
    );
  }

  return <AutomationForm key={rule.data.id} rule={rule.data} />;
}
