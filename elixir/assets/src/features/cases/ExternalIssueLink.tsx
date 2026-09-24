import { useId } from "react";
import { ExternalLink } from "lucide-react";
import { buttonVariants } from "@/components/ui/button";
import { cn } from "@/lib/utils";

// „Zobacz w Jira” / „Zobacz w Linear” (spec §4.4, §12): visually identical
// link buttons — same variant, size and icon, a new tab without opener or
// referrer. Only HTTPS links to the trusted host of each tracker become links;
// anything else (missing, `javascript:`, `data:`, another host, credentials in
// the URL) is a disabled button with an explanation, never `href="#"`.

export type ExternalTracker = "jira" | "linear";

const LABEL: Record<ExternalTracker, string> = {
  jira: "Zobacz w Jira",
  linear: "Zobacz w Linear",
};

const TRUSTED_HOST: Record<ExternalTracker, (host: string) => boolean> = {
  jira: (host) => host.endsWith(".atlassian.net") && host.length > ".atlassian.net".length,
  linear: (host) => host === "linear.app",
};

const linkClass = cn(
  buttonVariants({ variant: "outline", size: "sm" }),
  "h-auto min-h-[30px] gap-[7px] rounded-[7px] bg-card px-[9px] py-1.5 text-[11px] font-[550] text-foreground max-[600px]:flex-1",
);

function safeUrl(tracker: ExternalTracker, url: string | null | undefined): string | null {
  if (!url) return null;
  let parsed: URL;
  try {
    parsed = new URL(url);
  } catch {
    return null;
  }
  if (parsed.protocol !== "https:" || parsed.username || parsed.password) return null;
  return TRUSTED_HOST[tracker](parsed.hostname.toLowerCase()) ? parsed.href : null;
}

interface ExternalIssueLinkProps {
  tracker: ExternalTracker;
  url: string | null | undefined;
  /** Why there is no link, shown when `url` is missing or untrusted. */
  unavailableReason: string;
}

export function ExternalIssueLink({ tracker, url, unavailableReason }: ExternalIssueLinkProps) {
  const reasonId = useId();
  const href = safeUrl(tracker, url);
  const content = (
    <>
      {LABEL[tracker]}
      <ExternalLink aria-hidden strokeWidth={1.6} className="size-3.5" />
    </>
  );

  if (href) {
    return (
      <a href={href} target="_blank" rel="noopener noreferrer" className={linkClass}>
        {content}
      </a>
    );
  }

  const reason = url ? "Link nie prowadzi do zaufanego adresu." : unavailableReason;
  return (
    <span title={reason} className="inline-flex max-[600px]:flex-1">
      <button type="button" disabled aria-describedby={reasonId} className={linkClass}>
        {content}
      </button>
      <span id={reasonId} className="sr-only">
        {reason}
      </span>
    </span>
  );
}
