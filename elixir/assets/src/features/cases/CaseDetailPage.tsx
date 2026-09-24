import { useCallback, useEffect, useMemo } from "react";
import { Link, useParams, useSearchParams } from "react-router-dom";
import { ArrowLeft } from "lucide-react";
import { CaseDetail } from "@/features/cases/CaseDetail";
import { useCase } from "@/features/cases/useCase";
import { canonicalCaseParams, type CaseTab } from "@/features/cases/useCaseFilters";

// Standalone case detail (`/cases/:ref?tab=`), the canonical link of
// notifications (spec §4.3). It needs nothing from the Case Center: the case
// is loaded by its ref, the tab lives in the URL and an invalid tab is
// replaced by the default.

export function CaseDetailPage() {
  const { ref = "" } = useParams();
  const [params, setParams] = useSearchParams();
  const canonical = useMemo(() => canonicalCaseParams(params), [params]);
  const tab = ((canonical ?? params).get("tab") ?? "analysis") as CaseTab;
  const query = useCase(ref);

  useEffect(() => {
    if (canonical) setParams(canonical, { replace: true });
  }, [canonical, setParams]);

  const label = query.data ? (query.data.case.jira?.key ?? query.data.case.linear?.identifier ?? query.data.case.title) : null;
  useEffect(() => {
    document.title = `${label ?? "Sprawa"} — Harmony`;
  }, [label]);

  const onTabChange = useCallback(
    (next: CaseTab) =>
      setParams(
        (previous) => {
          const search = new URLSearchParams(previous);
          if (next === "analysis") search.delete("tab");
          else search.set("tab", next);
          return search;
        },
        { replace: true },
      ),
    [setParams],
  );

  return (
    <div className="grid gap-4">
      <Link to="/" className="inline-flex w-fit items-center gap-1.5 text-xs text-muted-foreground hover:text-foreground">
        <ArrowLeft aria-hidden className="size-3.5" strokeWidth={1.6} />
        Centrum spraw
      </Link>
      <div className="rounded-[11px] border bg-card px-[26px] py-[23px] shadow-[0_1px_2px_#20242f0a] max-[1150px]:p-5">
        <CaseDetail key={ref} caseRef={ref} tab={tab} onTabChange={onTabChange} titleAs="h1" />
      </div>
    </div>
  );
}
