import { RunningColumn } from "@/features/project/components/RunningColumn";
import { RetryBlockedColumn } from "@/features/project/components/RetryBlockedColumn";
import { HumanReviewColumn } from "@/features/project/components/HumanReviewColumn";
import { WorkRunHistoryTable } from "@/features/project/components/WorkRunHistoryTable";
import type { ProjectSummary } from "@/types/contract";

interface WorkTabProps {
  summary: ProjectSummary;
  slug: string;
}

export function WorkTab({ summary, slug }: WorkTabProps) {
  return (
    <div className="space-y-6">
      <div className="grid gap-4 lg:grid-cols-3">
        <RunningColumn rows={summary.running} slug={slug} />
        <RetryBlockedColumn retrying={summary.retrying} blocked={summary.blocked} slug={slug} />
        <HumanReviewColumn prs={summary.human_review_prs} />
      </div>

      <section className="space-y-3">
        <h2 className="text-lg font-medium">History</h2>
        <WorkRunHistoryTable slug={slug} />
      </section>
    </div>
  );
}
