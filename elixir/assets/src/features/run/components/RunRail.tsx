import { useState } from "react";
import { Loader2 } from "lucide-react";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { Button } from "@/components/ui/button";
import { StatusBadge } from "@/components/StatusBadge";
import { ElapsedTime } from "@/components/ElapsedTime";
import { ConfirmDialog } from "@/components/ConfirmDialog";
import { useStopRun, useRetryRun } from "@/features/run/useRunActions";
import type { RunDetail, HumanReviewPR } from "@/types/contract";

interface PRLinkProps {
  pr: HumanReviewPR;
}

function PRLink({ pr }: PRLinkProps) {
  const prUrl = `https://github.com/${pr.github_owner}/${pr.github_repo}/pull/${pr.github_pr_number}`;
  const ciStatus =
    typeof pr.metadata?.ci_status === "string" ? pr.metadata.ci_status : null;

  return (
    <li className="flex flex-col gap-0.5 text-sm">
      <div className="flex items-center gap-2">
        <a
          href={prUrl}
          target="_blank"
          rel="noopener noreferrer"
          className="font-medium underline underline-offset-2"
        >
          #{pr.github_pr_number}
        </a>
        {pr.linear_identifier && (
          pr.linear_url ? (
            <a
              href={pr.linear_url}
              target="_blank"
              rel="noopener noreferrer"
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
        {ciStatus !== null && <StatusBadge status={ciStatus} raw />}
      </div>
    </li>
  );
}

interface RunRailProps {
  detail: RunDetail;
}

export function RunRail({ detail }: RunRailProps) {
  const stop = useStopRun(detail.identifier);
  const retry = useRetryRun(detail.identifier);
  const [confirmOpen, setConfirmOpen] = useState(false);

  const canStop =
    detail.status === "running" || detail.status === "blocked";
  const canRetry = detail.status === "retrying";

  return (
    <div className="flex flex-col gap-4">
      {/* Status block */}
      <Card>
        <CardHeader>
          <CardTitle>Stan</CardTitle>
        </CardHeader>
        <CardContent className="space-y-2 text-sm">
          <div className="flex items-center gap-2">
            <StatusBadge status={detail.status} />
          </div>
          {detail.turn_count != null && (
            <div className="flex items-center gap-2">
              <span className="text-muted-foreground">Tury</span>
              <span className="font-mono">{detail.turn_count}</span>
            </div>
          )}
          <div className="flex items-center gap-2">
            <span className="text-muted-foreground">Od startu</span>
            <ElapsedTime since={detail.started_at} />
          </div>
          {detail.last_event && (
            <div className="flex items-center gap-2">
              <span className="text-muted-foreground">Ostatnie zdarzenie</span>
              <span className="text-muted-foreground text-xs">{detail.last_event}</span>
            </div>
          )}
          <div className="flex items-center gap-2 pt-1">
            <Button
              variant="outline"
              size="sm"
              disabled={!canStop || stop.isPending}
              aria-label={stop.isPending ? "Zatrzymywanie przebiegu…" : "Zatrzymaj ten przebieg"}
              onClick={() => setConfirmOpen(true)}
            >
              {stop.isPending ? (
                <Loader2 className="size-4 animate-spin" />
              ) : null}
              Zatrzymaj
            </Button>
            <Button
              variant="outline"
              size="sm"
              disabled={!canRetry || retry.isPending}
              aria-label={retry.isPending ? "Ponawianie przebiegu…" : "Ponów ten przebieg teraz"}
              onClick={() => retry.mutate()}
            >
              {retry.isPending ? (
                <Loader2 className="size-4 animate-spin" />
              ) : null}
              Ponów teraz
            </Button>
          </div>
          <ConfirmDialog
            open={confirmOpen}
            onOpenChange={setConfirmOpen}
            title="Zatrzymać ten przebieg?"
            description="To miękkie zatrzymanie: Harmony przestaje śledzić bieżącą próbę, zwalnia miejsce i nie uruchamia jej ponownie w tym cyklu. Agent może jeszcze dokończyć bieżącą turę. Jeśli zgłoszenie w trackerze nadal jest aktywne, praca może wrócić przy kolejnym odpytaniu."
            confirmLabel="Zatrzymaj przebieg"
            destructive
            isPending={stop.isPending}
            onConfirm={() => stop.mutate(undefined, { onSettled: () => setConfirmOpen(false) })}
          />
        </CardContent>
      </Card>

      {/* Tokens block */}
      <Card>
        <CardHeader>
          <CardTitle>Tokeny</CardTitle>
        </CardHeader>
        <CardContent className="text-sm">
          {detail.tokens ? (
            <dl className="space-y-1">
              <div className="flex items-center justify-between">
                <dt className="text-muted-foreground">Wejście</dt>
                <dd className="font-mono">{detail.tokens.input_tokens.toLocaleString("pl-PL")}</dd>
              </div>
              <div className="flex items-center justify-between">
                <dt className="text-muted-foreground">Wyjście</dt>
                <dd className="font-mono">{detail.tokens.output_tokens.toLocaleString("pl-PL")}</dd>
              </div>
              <div className="flex items-center justify-between">
                <dt className="text-muted-foreground">Razem</dt>
                <dd className="font-mono">{detail.tokens.total_tokens.toLocaleString("pl-PL")}</dd>
              </div>
            </dl>
          ) : (
            <p className="text-muted-foreground">Brak danych o tokenach.</p>
          )}
        </CardContent>
      </Card>

      {/* Pull requests block */}
      <Card>
        <CardHeader>
          <CardTitle>Pull requesty</CardTitle>
        </CardHeader>
        <CardContent className="text-sm">
          {detail.pull_requests.length === 0 ? (
            <p className="text-muted-foreground">Brak pull requestów.</p>
          ) : (
            <ul className="space-y-3">
              {detail.pull_requests.map((pr) => (
                <PRLink key={pr.id} pr={pr} />
              ))}
            </ul>
          )}
        </CardContent>
      </Card>

      {/* Artifacts block */}
      <Card>
        <CardHeader>
          <CardTitle>Artefakty</CardTitle>
        </CardHeader>
        <CardContent className="text-sm">
          {detail.artifacts.length === 0 ? (
            <p className="text-muted-foreground">Brak artefaktów.</p>
          ) : (
            <ul className="space-y-1">
              {detail.artifacts.map((artifact) => (
                <li key={artifact.id} className="flex items-center gap-2">
                  <span className="text-muted-foreground">{artifact.kind}</span>
                  <span className="font-mono text-xs">{artifact.path}</span>
                </li>
              ))}
            </ul>
          )}
        </CardContent>
      </Card>

      {/* Workspace block */}
      <Card>
        <CardHeader>
          <CardTitle>Katalog roboczy</CardTitle>
        </CardHeader>
        <CardContent className="space-y-1 text-sm">
          <div className="flex items-center gap-2">
            <span className="text-muted-foreground">Ścieżka</span>
            <span className="font-mono text-xs">
              {detail.workspace?.path ?? "—"}
            </span>
          </div>
          {detail.attempts.current_retry_attempt != null && (
            <div className="flex items-center gap-2">
              <span className="text-muted-foreground">
                Próba #{detail.attempts.current_retry_attempt}
              </span>
            </div>
          )}
        </CardContent>
      </Card>
    </div>
  );
}
