import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { StatusBadge } from "@/components/StatusBadge";
import type { HumanReviewPR } from "@/types/contract";

interface HumanReviewColumnProps {
  prs: HumanReviewPR[];
}

export function HumanReviewColumn({ prs }: HumanReviewColumnProps) {
  return (
    <Card>
      <CardHeader>
        <CardTitle>→ Human Review</CardTitle>
      </CardHeader>
      <CardContent>
        {prs.length === 0 ? (
          <p className="text-sm text-muted-foreground">Nothing waiting for review.</p>
        ) : (
          <ul className="space-y-3">
            {prs.map((pr) => {
              const prUrl = `https://github.com/${pr.github_owner}/${pr.github_repo}/pull/${pr.github_pr_number}`;
              const ciStatus =
                typeof pr.metadata?.ci_status === "string"
                  ? pr.metadata.ci_status
                  : null;

              return (
                <li key={pr.id} className="flex flex-col gap-0.5 text-sm">
                  <div className="flex items-center gap-2">
                    <a
                      href={prUrl}
                      target="_blank"
                      rel="noreferrer"
                      className="font-medium underline underline-offset-2"
                    >
                      #{pr.github_pr_number}
                    </a>
                    {pr.linear_identifier && (
                      pr.linear_url ? (
                        <a
                          href={pr.linear_url}
                          target="_blank"
                          rel="noreferrer"
                          className="font-mono text-xs text-muted-foreground underline underline-offset-2"
                        >
                          {pr.linear_identifier}
                        </a>
                      ) : (
                        <span className="font-mono text-xs text-muted-foreground">
                          {pr.linear_identifier}
                        </span>
                      )
                    )}
                    {ciStatus !== null && <StatusBadge status={ciStatus} />}
                  </div>
                </li>
              );
            })}
          </ul>
        )}
      </CardContent>
    </Card>
  );
}
